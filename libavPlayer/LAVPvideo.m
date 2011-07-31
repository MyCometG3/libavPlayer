/*
 *  LAVPvideo.c
 *  libavPlayer
 *
 *  Created by Takashi Mochizuki on 11/06/19.
 *  Copyright 2011 MyCometG3. All rights reserved.
 *
 */
/*
 This file is part of livavPlayer.
 
 livavPlayer is free software; you can redistribute it and/or modify
 it under the terms of the GNU General Public License as published by
 the Free Software Foundation; either version 2 of the License, or
 (at your option) any later version.
 
 SimplePlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with xvidEncoder; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include "LAVPcore.h"
#include "LAVPvideo.h"
#include "LAVPqueue.h"
#include "LAVPsubs.h"
#include "LAVPaudio.h"

/* =========================================================== */

#define FRAME_SKIP_FACTOR 0.05 /*0.05*/
#define AV_SYNC_THRESHOLD 0.01 /*0.01*/

/* =========================================================== */

void video_display(VideoState *is);

double compute_target_time(double frame_current_pts, VideoState *is);

int queue_picture(VideoState *is, AVFrame *src_frame, double pts, int64_t pos);
int output_picture2(VideoState *is, AVFrame *src_frame, double pts1, int64_t pos);
int get_video_frame(VideoState *is, AVFrame *frame, int64_t *pts, AVPacket *pkt);

#if ALLOW_GPL_CODE
extern void copy_planar_YUV420_to_2vuy(size_t width, size_t height, 
									   uint8_t *baseAddr_y, size_t rowBytes_y, 
									   uint8_t *baseAddr_u, size_t rowBytes_u, 
									   uint8_t *baseAddr_v, size_t rowBytes_v, 
									   uint8_t *baseAddr_2vuy, size_t rowBytes_2vuy);
#endif

/* =========================================================== */

#pragma mark -

int video_open(VideoState *is){
    int w,h;
	
    if (is->video_st && is->video_st->codec->width){
        w = is->video_st->codec->width;
        h = is->video_st->codec->height;
    } else {
        w = 640;
        h = 480;
    }
	
    is->width = w;
    is->height = h;
	
    return 0;
}

/* display the current picture, if any */
void video_display(VideoState *is)
{
	if (is->width * is->height == 0) {
		video_open(is);
	}
}

/* get the current video clock value */
double get_video_clock(VideoState *is)
{
    if (is->paused) {
        return is->video_current_pts;
    } else {
        return is->video_current_pts_drift + av_gettime() / 1000000.0;
    }
}

double compute_target_time(double frame_current_pts, VideoState *is)
{
    double delay, sync_threshold, diff;
	
    /* compute nominal delay */
    delay = frame_current_pts - is->frame_last_pts;
    if (delay <= 0 || delay >= 10.0) {
        /* if incorrect delay, use previous one */
        delay = is->frame_last_delay;
    } else {
        is->frame_last_delay = delay;
    }
    is->frame_last_pts = frame_current_pts;
	
    /* update delay to follow master synchronisation source */
    if (((is->av_sync_type == AV_SYNC_AUDIO_MASTER && is->audio_st) ||
         is->av_sync_type == AV_SYNC_EXTERNAL_CLOCK)) {
        /* if video is slave, we try to correct big delays by
		 duplicating or deleting a frame */
        diff = get_video_clock(is) - get_master_clock(is);
		
        /* skip or repeat frame. We take into account the
		 delay to compute the threshold. I still don't know
		 if it is the best guess */
        sync_threshold = FFMAX(AV_SYNC_THRESHOLD, delay);
        if (fabs(diff) < AV_NOSYNC_THRESHOLD) {
            if (diff <= -sync_threshold)
                delay = 0;
            else if (diff >= sync_threshold)
                delay = 2 * delay;
        }
    }
    is->frame_timer += delay;
	
    av_dlog(NULL, "video: delay=%0.3f pts=%0.3f A-V=%f\n",
            delay, frame_current_pts, -diff);
	
    return is->frame_timer;
}

/* called to display each frame */
void video_refresh_timer(void *opaque)
{
    VideoState *is = opaque;
    VideoPicture *vp;
	
    SubPicture *sp, *sp2;
	
    if (is->video_st) {
	retry:
		LAVPLockMutex(is->pictq_mutex);
        if (is->pictq_size > 0) {
            double time= av_gettime()/1000000.0;
            double next_target;
            /* dequeue the picture */
            vp = &is->pictq[is->pictq_rindex];
			
            if(time < vp->target_clock) {
				LAVPUnlockMutex(is->pictq_mutex);
                return;
			}
			if (is->pictq_size == 1 ) {
				LAVPUnlockMutex(is->pictq_mutex);
				return;
			}
            /* update current video pts */
            is->video_current_pts = vp->pts;
            is->video_current_pts_drift = is->video_current_pts - time;
            is->video_current_pos = vp->pos;
            if(is->pictq_size > 1){
                VideoPicture *nextvp= &is->pictq[(is->pictq_rindex+1)%VIDEO_PICTURE_QUEUE_SIZE];
                assert(nextvp->target_clock >= vp->target_clock);
                next_target= nextvp->target_clock;
            }else{
                next_target= vp->target_clock + is->video_clock - vp->pts; //FIXME pass durations cleanly
            }
			int framedrop = 1;
            if(framedrop && time > next_target){
                is->skip_frames *= 1.0 + FRAME_SKIP_FACTOR;
                if(is->pictq_size > 1 || time > next_target + 0.5){
                    /* update queue size and signal for next picture */
                    if (++is->pictq_rindex == VIDEO_PICTURE_QUEUE_SIZE)
                        is->pictq_rindex = 0;
					
                    is->pictq_size--;
                    LAVPCondSignal(is->pictq_cond);
                    LAVPUnlockMutex(is->pictq_mutex);
                    goto retry;
                }
            }
			LAVPUnlockMutex(is->pictq_mutex);
			
            if(is->subtitle_st) {
                if (is->subtitle_stream_changed) {
                    LAVPLockMutex(is->subpq_mutex);
					
                    while (is->subpq_size) {
                        free_subpicture(&is->subpq[is->subpq_rindex]);
						
                        /* update queue size and signal for next picture */
                        if (++is->subpq_rindex == SUBPICTURE_QUEUE_SIZE)
                            is->subpq_rindex = 0;
						
                        is->subpq_size--;
                    }
                    is->subtitle_stream_changed = 0;
					
                    LAVPCondSignal(is->subpq_cond);
                    LAVPUnlockMutex(is->subpq_mutex);
                } else {
					LAVPLockMutex(is->subpq_mutex);
                    if (is->subpq_size > 0) {
                        sp = &is->subpq[is->subpq_rindex];
						
                        if (is->subpq_size > 1)
                            sp2 = &is->subpq[(is->subpq_rindex + 1) % SUBPICTURE_QUEUE_SIZE];
                        else
                            sp2 = NULL;
						
                        if ((is->video_current_pts > (sp->pts + ((float) sp->sub.end_display_time / 1000)))
							|| (sp2 && is->video_current_pts > (sp2->pts + ((float) sp2->sub.start_display_time / 1000))))
                        {
                            free_subpicture(sp);
							
                            /* update queue size and signal for next picture */
                            if (++is->subpq_rindex == SUBPICTURE_QUEUE_SIZE)
                                is->subpq_rindex = 0;
							
                            is->subpq_size--;
                            LAVPCondSignal(is->subpq_cond);
                        }
                    }
					LAVPUnlockMutex(is->subpq_mutex);
                }
            }
			
            /* display picture */
			video_display(is);
			
            LAVPLockMutex(is->pictq_mutex);
			
            /* update queue size and signal for next picture */
            if (++is->pictq_rindex == VIDEO_PICTURE_QUEUE_SIZE)
                is->pictq_rindex = 0;
			
            is->pictq_size--;
            LAVPCondSignal(is->pictq_cond);
        }
		LAVPUnlockMutex(is->pictq_mutex);
    }
    if (is->show_status) {
        static int64_t last_time;
        int64_t cur_time;
        int aqsize, vqsize, sqsize;
        double av_diff;
		
        cur_time = av_gettime();
        if (!last_time || (cur_time - last_time) >= 30000) {
            aqsize = 0;
            vqsize = 0;
            sqsize = 0;
            if (is->audio_st)
                aqsize = is->audioq.size;
            if (is->video_st)
                vqsize = is->videoq.size;
            if (is->subtitle_st)
                sqsize = is->subtitleq.size;
            av_diff = 0;
            if (is->audio_st && is->video_st)
                av_diff = get_audio_clock(is) - get_video_clock(is);
            printf("%7.2f A-V:%7.3f s:%3.1f aq=%5dKB vq=%5dKB sq=%5dB f=%"PRId64"/%"PRId64"   \r",
                   get_master_clock(is), av_diff, FFMAX(is->skip_frames-1, 0), aqsize / 1024, vqsize / 1024, sqsize, is->pts_ctx.num_faulty_dts, is->pts_ctx.num_faulty_pts);
            fflush(stdout);
            last_time = cur_time;
        }
    }
}

/* allocate a picture (needs to do that in main thread to avoid
 potential locking problems */
void alloc_picture(void *opaque)
{
    VideoState *is = opaque;
    VideoPicture *vp;
	
    vp = &is->pictq[is->pictq_windex];
	
    if (vp->bmp) {
        avpicture_free((AVPicture*)vp->bmp);
		av_free(vp->bmp);
		vp->bmp = NULL;
	}
	
    vp->width   = is->video_st->codec->width;
    vp->height  = is->video_st->codec->height;
    vp->pix_fmt = is->video_st->codec->pix_fmt;
	
	// for SIMD accelaration: 16bytes alignment //
	AVFrame *picture = avcodec_alloc_frame();
	int ret = av_image_alloc(picture->data, picture->linesize, vp->width, vp->height, PIX_FMT_YUV420P, 0x10);
	assert(ret > 0);
	vp->bmp = picture;
	
    LAVPLockMutex(is->pictq_mutex);
    vp->allocated = 1;
    LAVPCondSignal(is->pictq_cond);
    LAVPUnlockMutex(is->pictq_mutex);
}

/**
 *
 * @param pts the dts of the pkt / pts of the frame and guessed if not known
 */
int queue_picture(VideoState *is, AVFrame *src_frame, double pts, int64_t pos)
{
    VideoPicture *vp;
	
    /* wait until we have space to put a new picture */
    LAVPLockMutex(is->pictq_mutex);
	
    if(is->pictq_size>=VIDEO_PICTURE_QUEUE_SIZE && !is->refresh)
        is->skip_frames= FFMAX(1.0 - FRAME_SKIP_FACTOR, is->skip_frames * (1.0-FRAME_SKIP_FACTOR));
	
    while (is->pictq_size >= VIDEO_PICTURE_QUEUE_SIZE &&
           !is->videoq.abort_request) {
        LAVPCondWait(is->pictq_cond, is->pictq_mutex);
    }
    LAVPUnlockMutex(is->pictq_mutex);
	
    if (is->videoq.abort_request)
        return -1;
	
    vp = &is->pictq[is->pictq_windex];
	
    /* alloc or resize hardware picture buffer */
    if (!vp->bmp ||
        vp->width != is->video_st->codec->width ||
        vp->height != is->video_st->codec->height) {
		
        vp->allocated = 0;
		
		id decoder = is->decoder;
		NSThread *thread = (NSThread*)is->decoderThread;
		[decoder performSelector:@selector(allocPicture) onThread:thread withObject:nil waitUntilDone:NO];
		
        /* wait until the picture is allocated */
        LAVPLockMutex(is->pictq_mutex);
        while (!vp->allocated && !is->videoq.abort_request) {
            LAVPCondWait(is->pictq_cond, is->pictq_mutex);
        }
        LAVPUnlockMutex(is->pictq_mutex);
		
        if (is->videoq.abort_request)
            return -1;
    }
	
    /* if the frame is not skipped, then display it */
    if (vp->bmp) {
        AVPicture pict;
		
        LAVPLockMutex(is->pictq_mutex);
		
        /* get a pointer on the bitmap */
        memset(&pict,0,sizeof(AVPicture));
        pict.data[0] = vp->bmp->data[0];
        pict.data[1] = vp->bmp->data[1];
        pict.data[2] = vp->bmp->data[2];
		
        pict.linesize[0] = vp->bmp->linesize[0];
        pict.linesize[1] = vp->bmp->linesize[1];
        pict.linesize[2] = vp->bmp->linesize[2];
		
		av_image_copy_plane(pict.data[0], pict.linesize[0], 
							(const uint8_t *)src_frame->data[0], src_frame->linesize[0], 
							src_frame->linesize[0], vp->height);
		av_image_copy_plane(pict.data[1], pict.linesize[1], 
							(const uint8_t *)src_frame->data[1], src_frame->linesize[1], 
							src_frame->linesize[1], vp->height/2);
		av_image_copy_plane(pict.data[2], pict.linesize[2], 
							(const uint8_t *)src_frame->data[2], src_frame->linesize[2], 
							src_frame->linesize[2], vp->height/2);
		
        vp->pts = pts;
        vp->pos = pos;
		
        /* now we can update the picture count */
        if (++is->pictq_windex == VIDEO_PICTURE_QUEUE_SIZE)
            is->pictq_windex = 0;
        vp->target_clock= compute_target_time(vp->pts, is);
		
        is->pictq_size++;
        LAVPUnlockMutex(is->pictq_mutex);
    }
    return 0;
}

/**
 * compute the exact PTS for the picture if it is omitted in the stream
 * @param pts1 the dts of the pkt / pts of the frame
 */
int output_picture2(VideoState *is, AVFrame *src_frame, double pts1, int64_t pos)
{
    double frame_delay, pts;
	
    pts = pts1;
	
    if (pts != 0) {
        /* update video clock with pts, if present */
        is->video_clock = pts;
    } else {
        pts = is->video_clock;
    }
    /* update video clock for next frame */
    frame_delay = av_q2d(is->video_st->codec->time_base);
    /* for MPEG2, the frame can be repeated, so we update the
	 clock accordingly */
    frame_delay += src_frame->repeat_pict * (frame_delay * 0.5);
    is->video_clock += frame_delay;
	
    return queue_picture(is, src_frame, pts, pos);
}

int get_video_frame(VideoState *is, AVFrame *frame, int64_t *pts, AVPacket *pkt)
{
    int got_picture, i;
	
    if (packet_queue_get(&is->videoq, pkt, 1) < 0)
        return -1;
	
    if (pkt->data == is->videoq.flush_pkt.data) {
        avcodec_flush_buffers(is->video_st->codec);
		
        LAVPLockMutex(is->pictq_mutex);
        //Make sure there are no long delay timers (ideally we should just flush the que but thats harder)
        for (i = 0; i < VIDEO_PICTURE_QUEUE_SIZE; i++) {
            is->pictq[i].target_clock= 0;
        }
        while (is->pictq_size && !is->videoq.abort_request) {
            LAVPCondWait(is->pictq_cond, is->pictq_mutex);
        }
        is->video_current_pos = -1;
        LAVPUnlockMutex(is->pictq_mutex);
		
        init_pts_correction(&is->pts_ctx);
        is->frame_last_pts = AV_NOPTS_VALUE;
        is->frame_last_delay = 0;
        is->frame_timer = (double)av_gettime() / 1000000.0;
        is->skip_frames = 1;
        is->skip_frames_index = 0;
        return 0;
    }
	
    avcodec_decode_video2(is->video_st->codec,
						  frame, &got_picture,
						  pkt);
	
    if (got_picture) {
        if (is->decoder_reorder_pts == -1) {
            *pts = guess_correct_pts(&is->pts_ctx, frame->pkt_pts, frame->pkt_dts);
        } else if (is->decoder_reorder_pts) {
            *pts = frame->pkt_pts;
        } else {
            *pts = frame->pkt_dts;
        }
		
        if (*pts == AV_NOPTS_VALUE) {
            *pts = 0;
        }
		
        is->skip_frames_index += 1;
        if(is->skip_frames_index >= is->skip_frames){
            is->skip_frames_index -= FFMAX(is->skip_frames, 1.0);
            return 1;
        }
		
    }
    return 0;
}

int video_thread(void *arg)
{
    VideoState *is = arg;
    AVFrame *frame= avcodec_alloc_frame();
    int64_t pts_int;
    double pts;
    int ret;
	
	is->lastPTScopied = -1;
	is->decoder_reorder_pts = -1;
	
    for(;;) {
		NSAutoreleasePool *pool = [NSAutoreleasePool new];
		
        AVPacket pkt;
        while (is->paused && !is->videoq.abort_request)
            usleep(10*1000);
        ret = get_video_frame(is, frame, &pts_int, &pkt);
		
        if (ret < 0) {
			[pool drain];
			goto the_end;
		}
				
        if (!ret) {
			[pool drain];
            continue;
		}
		
        pts = pts_int*av_q2d(is->video_st->time_base);
		
        ret = output_picture2(is, frame, pts,  pkt.pos);
        av_free_packet(&pkt);
        if (ret < 0) {
			[pool drain];
            goto the_end;
		}
		if (is->step)
			if (is)
				stream_pause(is);
		
		[pool drain];
    }
the_end:
    av_free(frame);
#if !ALLOW_GPL_CODE
	if (is->sws420to422) 
		sws_freeContext(is->sws420to422);
#endif
    return 0;
}

/* ========================================================================= */

void init_pts_correction(PtsCorrectionContext *ctx)
{
    ctx->num_faulty_pts = ctx->num_faulty_dts = 0;
    ctx->last_pts = ctx->last_dts = INT64_MIN;
}

int64_t guess_correct_pts(PtsCorrectionContext *ctx, int64_t reordered_pts, int64_t dts)
{
    int64_t pts = AV_NOPTS_VALUE;
	
    if (dts != AV_NOPTS_VALUE) {
        ctx->num_faulty_dts += dts <= ctx->last_dts;
        ctx->last_dts = dts;
    }
    if (reordered_pts != AV_NOPTS_VALUE) {
        ctx->num_faulty_pts += reordered_pts <= ctx->last_pts;
        ctx->last_pts = reordered_pts;
    }
    if ((ctx->num_faulty_pts<=ctx->num_faulty_dts || dts == AV_NOPTS_VALUE)
		&& reordered_pts != AV_NOPTS_VALUE)
        pts = reordered_pts;
    else
        pts = dts;
	
    return pts;
}

/* ========================================================================= */
#pragma mark -

int hasImage(void *opaque, double_t targetpts)
{
	VideoState *is = opaque;
	
	LAVPLockMutex(is->pictq_mutex);
	
	if (is->pictq_size > 0) {
		VideoPicture *vp = NULL;
		VideoPicture *tmp = NULL;
		
		if (!vp) {
			for (int index = 0; index < is->pictq_size; index++) {
				tmp = &is->pictq[index];
				
				if (0.0 <= tmp->pts && tmp->pts <= targetpts) {
					if (!vp) {
						vp = tmp;
					} else if (tmp->pts > vp->pts) {
						vp = tmp;
					}
				}
			}
		}
		if (!vp) {
			for (int index = 0; index < is->pictq_size; index++) {
				tmp = &is->pictq[index];
				
				if (!vp) {
					vp = tmp;
				} else if (tmp->pts < vp->pts) {
					vp = tmp;
				}
			}
		}
		
		if (vp) {
			if (vp->pts == is->lastPTScopied) goto bail;
			
			LAVPUnlockMutex(is->pictq_mutex);
			return 1;
		} else {
			NSLog(@"ERROR: vp == NULL (%s)", __FUNCTION__);
		}
	} else {
		NSLog(@"ERROR: is->pictq_size == 0 (%s)", __FUNCTION__);
	}
	
bail:
	LAVPUnlockMutex(is->pictq_mutex);
	return 0;
}

int copyImage(void *opaque, double_t targetpts, uint8_t* data, int pitch) 
{
	VideoState *is = opaque;
	uint8_t * out[4] = {0};
	out[0] = data;
	assert(data);
	
#if !ALLOW_GPL_CODE
	if (!is->sws420to422) {
		is->sws420to422 = sws_getContext(is->width, is->height,
										 PIX_FMT_YUV420P,
										 is->width, is->height,
										 PIX_FMT_UYVY422,
										 SWS_BILINEAR,NULL, NULL, NULL);
		assert (is->sws420to422);
	}
#endif
	
	LAVPLockMutex(is->pictq_mutex);
	
	if (is->pictq_size > 0) {
		VideoPicture *vp = NULL;
		VideoPicture *tmp = NULL;
		
		if (!vp) {
			for (int index = 0; index < is->pictq_size; index++) {
				tmp = &is->pictq[index];
				
				if (0.0 <= tmp->pts && tmp->pts <= targetpts) {
					if (!vp) {
						vp = tmp;
					} else if (tmp->pts > vp->pts) {
						vp = tmp;
					}
				}
			}
		}
		if (!vp) {
			for (int index = 0; index < is->pictq_size; index++) {
				tmp = &is->pictq[index];
				
				if (!vp) {
					vp = tmp;
				} else if (tmp->pts < vp->pts) {
					vp = tmp;
				}
			}
		}
		
		if (vp) {
			int result = 0;
			
			if (vp->pts == is->lastPTScopied) goto bail;
			
#if ALLOW_GPL_CODE
			uint8_t *in[4] = {vp->bmp->data[0], vp->bmp->data[1], vp->bmp->data[2], vp->bmp->data[3]};
			size_t inpitch[4] = {vp->bmp->linesize[0], vp->bmp->linesize[1], vp->bmp->linesize[2], vp->bmp->linesize[3]};
			copy_planar_YUV420_to_2vuy(vp->width, vp->height, 
									   in[0], inpitch[0], 
									   in[1], inpitch[1], 
									   in[2], inpitch[2], 
									   data, pitch);
			result = 1;
#else
			const uint8_t *in[4] = {vp->bmp->data[0], vp->bmp->data[1], vp->bmp->data[2], vp->bmp->data[3]};
			result = sws_scale(is->sws420to422, 
							   in, vp->bmp->linesize, 0, vp->height, 
							   out, &pitch);
#endif
			
			if (result > 0) {
				//NSLog(@"copyImage(%.3lf) (%d); %.3lf", targetpts, is->pictq_size, vp->pts-targetpts);
				is->lastPTScopied = vp->pts;
				
				LAVPUnlockMutex(is->pictq_mutex);
				return 1;
			} else {
				NSLog(@"ERROR: result != 0 (%s)", __FUNCTION__);
			}
		} else {
			NSLog(@"ERROR: vp == NULL (%s)", __FUNCTION__);
		}
	} else {
		NSLog(@"ERROR: is->pictq_size == 0 (%s)", __FUNCTION__);
	}
	
bail:
	LAVPUnlockMutex(is->pictq_mutex);
	return 0;
}

int hasImageCurrent(void *opaque)
{
	VideoState *is = opaque;
	
	LAVPLockMutex(is->pictq_mutex);
	
	if (is->pictq_size > 0) {
		int index = is->pictq_rindex;
		VideoPicture *vp = &is->pictq[index];
		if(vp) {
			if (vp->pts == is->lastPTScopied) goto bail;
			
			LAVPUnlockMutex(is->pictq_mutex);
			return 1;
		} else {
			NSLog(@"ERROR: vp == NULL (%s)", __FUNCTION__);
		}
	} else {
		NSLog(@"ERROR: is->pictq_size == 0 (%s)", __FUNCTION__);
	}
	
bail:
	LAVPUnlockMutex(is->pictq_mutex);
	return 0;
}

int copyImageCurrent(void *opaque, double_t *targetpts, uint8_t* data, int pitch) 
{
	VideoState *is = opaque;
	uint8_t * out[4] = {0};
	out[0] = data;
	assert(data);
	
#if !ALLOW_GPL_CODE
	if (!is->sws420to422) {
		is->sws420to422 = sws_getContext(is->width, is->height,
										 PIX_FMT_YUV420P,
										 is->width, is->height,
										 PIX_FMT_UYVY422,
										 SWS_BICUBIC,NULL, NULL, NULL);
		assert (is->sws420to422);
	}
#endif
	
	LAVPLockMutex(is->pictq_mutex);
	
	if (is->pictq_size > 0) {
		int index = is->pictq_rindex;
		VideoPicture *vp = &is->pictq[index];
		
		if (vp) {
			int result = 0;
			
			if (vp->pts == is->lastPTScopied) goto bail;
			
#if ALLOW_GPL_CODE
			uint8_t *in[4] = {vp->bmp->data[0], vp->bmp->data[1], vp->bmp->data[2], vp->bmp->data[3]};
			size_t inpitch[4] = {vp->bmp->linesize[0], vp->bmp->linesize[1], vp->bmp->linesize[2], vp->bmp->linesize[3]};
			copy_planar_YUV420_to_2vuy(vp->width, vp->height, 
									   in[0], inpitch[0], 
									   in[1], inpitch[1], 
									   in[2], inpitch[2], 
									   data, pitch);
			result = 1;
#else
			const uint8_t *in[4] = {vp->bmp->data[0], vp->bmp->data[1], vp->bmp->data[2], vp->bmp->data[3]};
			result = sws_scale(is->sws420to422, 
							   in, vp->bmp->linesize, 0, vp->height, 
							   out, &pitch);
#endif
			
			if (result > 0) {
				//NSLog(@"NOTE: copyImageCurrent() done. = %lf", vp->pts);
				is->lastPTScopied = vp->pts;
				*targetpts = vp->pts;
				
				LAVPUnlockMutex(is->pictq_mutex);
				return 1;
			} else {
				NSLog(@"ERROR: result != 0 (%s)", __FUNCTION__);
			}
		} else {
			NSLog(@"ERROR: vp == NULL (%s)", __FUNCTION__);
		}
	} else {
		NSLog(@"ERROR: is->pictq_size == 0 (%s)", __FUNCTION__);
	}
	
bail:
	LAVPUnlockMutex(is->pictq_mutex);
	return 0;
}
