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
 
 livavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include "LAVPcore.h"
#include "LAVPvideo.h"
#include "LAVPqueue.h"
#include "LAVPsubs.h"
#include "LAVPaudio.h"

/* =========================================================== */


/* =========================================================== */

void video_display(VideoState *is);

double compute_target_delay(double delay, VideoState *is);

int queue_picture(VideoState *is, AVFrame *src_frame, double pts, double duration, int64_t pos, int serial);
int get_video_frame(VideoState *is, AVFrame *frame, AVPacket *pkt, int *serial);
void video_refresh(void *opaque, double *remaining_time);

extern void stream_toggle_pause(VideoState *is);
extern void toggle_pause(VideoState *is);
extern void free_subpicture(SubPicture *sp);

#if ALLOW_GPL_CODE
extern void copy_planar_YUV420_to_2vuy(size_t width, size_t height, 
									   uint8_t *baseAddr_y, size_t rowBytes_y, 
									   uint8_t *baseAddr_u, size_t rowBytes_u, 
									   uint8_t *baseAddr_v, size_t rowBytes_v, 
									   uint8_t *baseAddr_2vuy, size_t rowBytes_2vuy);
extern void CVF_CopyPlane(const UInt8* Sbase, int Sstride, int Srow, UInt8* Dbase, int Dstride, int Drow);
#endif

/* =========================================================== */

#pragma mark -

void free_picture(VideoPicture *vp)
{
    if (vp->bmp) {
        avpicture_free((AVPicture*)vp->bmp);
        av_free(vp->bmp);
        vp->bmp = NULL;
    }
}

/*
 TODO:
 fill_rectangle()
 fill_border()
 calculate_display_rect()
 video_image_display()
 compute_mod()
 video_audio_display()
 */

/* display the current picture, if any */
void video_display(VideoState *is)
{
    if (0 == is->width * is->height ) // LAVP: zero rect is not allowed
        video_open(is, NULL);
    if (is->audio_st && is->show_mode != SHOW_MODE_VIDEO) {
        //video_audio_display(is); /* TODO */
    } else if (is->video_st) {
        //video_image_display(is); /* TODO */
    }
}

#pragma mark -

int video_open(VideoState *is, VideoPicture *vp){
    /* LAVP: No need for SDL support; Independent from screen rect */
	int w,h;
	
    if (vp && vp->width * vp->height) {
        w = vp->width;
        h = vp->height;
    } else if (is->video_st && is->video_st->codec->width){
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

double compute_target_delay(double delay, VideoState *is)
{
    double sync_threshold, diff;
    
    /* update delay to follow master synchronisation source */
    if (get_master_sync_type(is) != AV_SYNC_VIDEO_MASTER) {
        /* if video is slave, we try to correct big delays by
         duplicating or deleting a frame */
        diff = get_clock(&is->vidclk) - get_master_clock(is);
        
        /* skip or repeat frame. We take into account the
         delay to compute the threshold. I still don't know
         if it is the best guess */
        sync_threshold = FFMAX(AV_SYNC_THRESHOLD_MIN, FFMIN(AV_SYNC_THRESHOLD_MAX, delay));
        if (!isnan(diff) && fabs(diff) < is->max_frame_duration) {
            if (diff <= -sync_threshold)
                delay = FFMAX(0, delay + diff);
            else if (diff >= sync_threshold && delay > AV_SYNC_FRAMEDUP_THRESHOLD)
                delay = delay + diff;
            else if (diff >= sync_threshold)
                delay = 2 * delay;
        }
    }
    
    av_dlog(NULL, "video: delay=%0.3f A-V=%f\n",
            delay, -diff);
    
    return delay;
}

static double vp_duration(VideoState *is, VideoPicture *vp, VideoPicture *nextvp) {
    if (vp->serial == nextvp->serial) {
        double duration = nextvp->pts - vp->pts;
        if (isnan(duration) || duration <= 0 || duration > is->max_frame_duration)
            return vp->duration;
        else
            return duration;
    } else {
        return 0.0;
    }
}

static void pictq_next_picture(VideoState *is) {
    /* update queue size and signal for next picture */
    if (++is->pictq_rindex == VIDEO_PICTURE_QUEUE_SIZE)
        is->pictq_rindex = 0;
    
    LAVPLockMutex(is->pictq_mutex);
    is->pictq_size--;
    LAVPCondSignal(is->pictq_cond);
    LAVPUnlockMutex(is->pictq_mutex);
}

static int pictq_prev_picture(VideoState *is) {
    VideoPicture *prevvp;
    int ret = 0;
    /* update queue size and signal for the previous picture */
    prevvp = &is->pictq[(is->pictq_rindex + VIDEO_PICTURE_QUEUE_SIZE - 1) % VIDEO_PICTURE_QUEUE_SIZE];
    if (prevvp->allocated && prevvp->serial == is->videoq.serial) {
        LAVPLockMutex(is->pictq_mutex);
        if (is->pictq_size < VIDEO_PICTURE_QUEUE_SIZE) {
            if (--is->pictq_rindex == -1)
                is->pictq_rindex = VIDEO_PICTURE_QUEUE_SIZE - 1;
            is->pictq_size++;
            ret = 1;
        }
        LAVPCondSignal(is->pictq_cond);
        LAVPUnlockMutex(is->pictq_mutex);
    }
    return ret;
}

static void update_video_pts(VideoState *is, double pts, int64_t pos, int serial) {
    /* update current video pts */
    set_clock(&is->vidclk, pts, serial);
    sync_clock_to_slave(&is->extclk, &is->vidclk);
    is->video_current_pos = pos;
}

/* LAVP: called from LAVPDecoder.m in RunLoop under is->decoderThread */
void refresh_loop_wait_event(VideoState *is) {
    double remaining_time = 0.0;
    
    // LAVP: use remaining time to avoid over-run
    if (is->remaining_time > 1.0)
        return;
    
    if (is->show_mode != SHOW_MODE_NONE && (!is->paused || is->force_refresh))
        video_refresh(is, &remaining_time);
    
    // 
    is->remaining_time = remaining_time;
}

/* called to display each frame */
void video_refresh(void *opaque, double *remaining_time)
{
	VideoState *is = opaque;
    double time;
	
	SubPicture *sp, *sp2;
	
    if (!is->paused && get_master_sync_type(is) == AV_SYNC_EXTERNAL_CLOCK && is->realtime)
        check_external_clock_speed(is);
    
    if (!is->display_disable && is->show_mode != SHOW_MODE_VIDEO && is->audio_st) {
        time = av_gettime() / 1000000.0;
        if (is->force_refresh || is->last_vis_time + is->rdftspeed < time) {
            video_display(is);
            is->last_vis_time = time;
        }
        *remaining_time = FFMIN(*remaining_time, is->last_vis_time + is->rdftspeed - time);
    }
    
	if (is->video_st) {
        int redisplay = 0;
        if (is->force_refresh)
            redisplay = pictq_prev_picture(is);
	retry:
        if (is->pictq_size == 0) {
            // nothing to do, no picture to display in the queue
        } else {
            double last_duration, duration, delay;
            VideoPicture *vp, *lastvp;
            
			/* dequeue the picture */
			vp = &is->pictq[is->pictq_rindex];
            lastvp = &is->pictq[(is->pictq_rindex + VIDEO_PICTURE_QUEUE_SIZE - 1) % VIDEO_PICTURE_QUEUE_SIZE];
            
            if (vp->serial != is->videoq.serial) {
                pictq_next_picture(is);
                is->video_current_pos = -1;
                redisplay = 0;
                goto retry;
            }
            
            if (lastvp->serial != vp->serial && !redisplay)
                is->frame_timer = av_gettime() / 1000000.0;
            
            if (is->paused)
                goto display;
            
            /* compute nominal last_duration */
            last_duration = vp_duration(is, lastvp, vp);
            if (redisplay)
                delay = 0.0;
            else
                delay = compute_target_delay(last_duration, is);
            
            time= av_gettime()/1000000.0;
            if (time < is->frame_timer + delay && !redisplay) {
                *remaining_time = FFMIN(is->frame_timer + delay - time, *remaining_time);
                return;
            }
            
            is->frame_timer += delay;
            if (delay > 0 && time - is->frame_timer > AV_SYNC_THRESHOLD_MAX)
                is->frame_timer = time;
            
            LAVPLockMutex(is->pictq_mutex);
            if (!redisplay && !isnan(vp->pts))
                update_video_pts(is, vp->pts, vp->pos, vp->serial);
            LAVPUnlockMutex(is->pictq_mutex);
            
            if (is->pictq_size > 1) {
                VideoPicture *nextvp = &is->pictq[(is->pictq_rindex + 1) % VIDEO_PICTURE_QUEUE_SIZE];
                duration = vp_duration(is, vp, nextvp);
                if(!is->step && (redisplay || is->framedrop>0 || (is->framedrop && get_master_sync_type(is) != AV_SYNC_VIDEO_MASTER)) && time > is->frame_timer + duration){
                    if (!redisplay)
                        is->frame_drops_late++;
                    pictq_next_picture(is);
                    redisplay = 0;
                    goto retry;
                }
            }
			
			if(is->subtitle_st) {
                while (is->subpq_size > 0) {
                    sp = &is->subpq[is->subpq_rindex];
                    
                    if (is->subpq_size > 1)
                        sp2 = &is->subpq[(is->subpq_rindex + 1) % SUBPICTURE_QUEUE_SIZE];
                    else
                        sp2 = NULL;
                    
                    if (sp->serial != is->subtitleq.serial
                        || (is->vidclk.pts > (sp->pts + ((float) sp->sub.end_display_time / 1000)))
                        || (sp2 && is->vidclk.pts > (sp2->pts + ((float) sp2->sub.start_display_time / 1000))))
                    {
                        free_subpicture(sp);
                        
                        /* update queue size and signal for next picture */
                        if (++is->subpq_rindex == SUBPICTURE_QUEUE_SIZE)
                            is->subpq_rindex = 0;
                        
                        LAVPLockMutex(is->subpq_mutex);
                        is->subpq_size--;
                        LAVPCondSignal(is->subpq_cond);
                        LAVPUnlockMutex(is->subpq_mutex);
                    } else {
                        break;
                    }
                }
			}
			
display:
            /* display picture */
            if (!is->display_disable && is->show_mode == SHOW_MODE_VIDEO)
                video_display(is);
            
            pictq_next_picture(is);
            
            if (is->step && !is->paused)
                stream_toggle_pause(is);
		}
	}
    is->force_refresh = 0;
#if 0
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
                av_diff = get_clock(&is->audclk) - get_clock(&is->vidclk);
            else if (is->video_st)
                av_diff = get_master_clock(is) - get_clock(&is->vidclk);
            else if (is->audio_st)
                av_diff = get_master_clock(is) - get_clock(&is->audclk);
			printf("%7.2f %s:%7.3f fd=%4d aq=%5dKB vq=%5dKB sq=%5dB f=%"PRId64"/%"PRId64"   \r",
                   get_master_clock(is),
                   (is->audio_st && is->video_st) ? "A-V" : (is->video_st ? "M-V" : (is->audio_st ? "M-A" : "   ")),
                   av_diff,
                   is->frame_drops_early + is->frame_drops_late,
                   aqsize / 1024,
                   vqsize / 1024,
                   sqsize,
                   is->video_st ? is->video_st->codec->pts_correction_num_faulty_dts : 0,
                   is->video_st ? is->video_st->codec->pts_correction_num_faulty_pts : 0);
			fflush(stdout);
			last_time = cur_time;
		}
	}
#endif
}

/* allocate a picture (needs to do that in main thread to avoid
 potential locking problems */
void alloc_picture(void *opaque)
{
    /* LAVP: Called via LAVPDecoder.allocPicture in is->decoderThread */
	VideoState *is = opaque;
	
    /* LAVP: Use AVFrame instead of SDL_YUVOverlay */
	AVFrame *picture = av_frame_alloc();
	int ret = av_image_alloc(picture->data, picture->linesize, 
							 is->video_st->codec->width, is->video_st->codec->height, PIX_FMT_YUV420P, 0x10);
	assert(ret > 0);
	
    //
	VideoPicture *vp;
    
	vp = &is->pictq[is->pictq_windex];
	
    free_picture(vp);

	video_open(is, vp);
    
	LAVPLockMutex(is->pictq_mutex);
    
	vp->pts     = -1;
	vp->width   = is->video_st->codec->width;
	vp->height  = is->video_st->codec->height;
	vp->bmp = picture;
	vp->allocated = 1;
	
	LAVPCondSignal(is->pictq_cond);
	LAVPUnlockMutex(is->pictq_mutex);
}

int queue_picture(VideoState *is, AVFrame *src_frame, double pts, double duration, int64_t pos, int serial)
{
	VideoPicture *vp;
    
#if defined(DEBUG_SYNC) && 0
    printf("frame_type=%c pts=%0.3f\n",
           av_get_picture_type_char(src_frame->pict_type), pts);
#endif
	
	/* wait until we have space to put a new picture */
	LAVPLockMutex(is->pictq_mutex);
	
    /* keep the last already displayed picture in the queue */
	while (is->pictq_size >= VIDEO_PICTURE_QUEUE_SIZE - 1 &&
		   !is->videoq.abort_request) {
		LAVPCondWait(is->pictq_cond, is->pictq_mutex);
	}
	LAVPUnlockMutex(is->pictq_mutex);
	
	if (is->videoq.abort_request)
		return -1;
	
	vp = &is->pictq[is->pictq_windex];
	
    vp->sar = src_frame->sample_aspect_ratio;
	
	/* alloc or resize hardware picture buffer */
	if (!vp->bmp || vp->reallocate || !vp->allocated ||
		vp->width != is->video_st->codec->width ||
		vp->height != is->video_st->codec->height) {
		
		vp->allocated = 0;
        vp->reallocate = 0;
        vp->width = src_frame->width;
        vp->height = src_frame->height;
		
        /* the allocation must be done in the main thread to avoid
         locking problems. */
        /* LAVP: Using is->decoderThread */
		id decoder = is->decoder;
		NSThread *thread = (NSThread*)is->decoderThread;
		[decoder performSelector:@selector(allocPicture) onThread:thread withObject:nil waitUntilDone:NO];
		
        /* wait until the picture is allocated */
		LAVPLockMutex(is->pictq_mutex);
        while (!vp->allocated && !is->videoq.abort_request) {
            LAVPCondWait(is->pictq_cond, is->pictq_mutex);
        }
        /* if the queue is aborted, we have to pop the pending ALLOC event or wait for the allocation to complete */
        if (is->videoq.abort_request) {
            while (!vp->allocated) {
                LAVPCondWait(is->pictq_cond, is->pictq_mutex);
            }
        }
		LAVPUnlockMutex(is->pictq_mutex);
		
		if (is->videoq.abort_request)
			return -1;
	}
	
	/* if the frame is not skipped, then display it */
	if (vp->bmp) {
        AVPicture pict = { { 0 } };
		
		/* get a pointer on the bitmap */
        /* LAVP: Using AVFrame */
		memset(&pict,0,sizeof(AVPicture));
		pict.data[0] = vp->bmp->data[0];
		pict.data[1] = vp->bmp->data[1];
		pict.data[2] = vp->bmp->data[2];
		
		pict.linesize[0] = vp->bmp->linesize[0];
		pict.linesize[1] = vp->bmp->linesize[1];
		pict.linesize[2] = vp->bmp->linesize[2];
		
        /* LAVP: duplicate or create YUV420P picture */
		if (src_frame->format == PIX_FMT_YUV420P) {
#if ALLOW_GPL_CODE
			CVF_CopyPlane((const UInt8 *)src_frame->data[0], src_frame->linesize[0], vp->height, pict.data[0], pict.linesize[0], vp->height);
			CVF_CopyPlane((const UInt8 *)src_frame->data[1], src_frame->linesize[1], vp->height, pict.data[1], pict.linesize[1], vp->height/2);
			CVF_CopyPlane((const UInt8 *)src_frame->data[2], src_frame->linesize[2], vp->height, pict.data[2], pict.linesize[2], vp->height/2);
#else
			av_image_copy_plane(pict.data[0], pict.linesize[0], 
								(const uint8_t *)src_frame->data[0], src_frame->linesize[0], 
								src_frame->linesize[0], vp->height);
			av_image_copy_plane(pict.data[1], pict.linesize[1], 
								(const uint8_t *)src_frame->data[1], src_frame->linesize[1], 
								src_frame->linesize[1], vp->height/2);
			av_image_copy_plane(pict.data[2], pict.linesize[2], 
								(const uint8_t *)src_frame->data[2], src_frame->linesize[2], 
								src_frame->linesize[2], vp->height/2);
#endif
		} else {
            /* convert image format */
			is->img_convert_ctx = sws_getCachedContext(is->img_convert_ctx,
													   vp->width, vp->height, src_frame->format,
													   vp->width, vp->height, AV_PIX_FMT_YUV420P,
													   is->sws_flags, NULL, NULL, NULL);
            if (is->img_convert_ctx == NULL) {
                av_log(NULL, AV_LOG_FATAL, "Cannot initialize the conversion context\n");
                exit(1);
            }
			sws_scale(is->img_convert_ctx, (void*)src_frame->data, src_frame->linesize,
					  0, vp->height, pict.data, pict.linesize);
		}
		
		vp->pts = pts;
        vp->duration = duration;
		vp->pos = pos;
        vp->serial = serial;
		
		/* now we can update the picture count */
		if (++is->pictq_windex == VIDEO_PICTURE_QUEUE_SIZE)
			is->pictq_windex = 0;
        
		LAVPLockMutex(is->pictq_mutex);
		is->pictq_size++;
		LAVPUnlockMutex(is->pictq_mutex);
	}
	return 0;
}

int get_video_frame(VideoState *is, AVFrame *frame, AVPacket *pkt, int *serial)
{
	int got_picture;
	
	if (packet_queue_get(&is->videoq, pkt, 1, serial) < 0)
		return -1;
	
    /* LAVP: Queue specific flush packet */
	if (pkt->data == is->videoq.flush_pkt.data) {
		avcodec_flush_buffers(is->video_st->codec);
		return 0;
	}
	
    if(avcodec_decode_video2(is->video_st->codec, frame, &got_picture, pkt) < 0)
        return 0;
	
    if (!got_picture && !pkt->data)
        is->video_finished = *serial;

	if (got_picture) {
        int ret = 1;
        double dpts = NAN;
        
		if (is->decoder_reorder_pts == -1) {
            frame->pts = av_frame_get_best_effort_timestamp(frame);
		} else if (is->decoder_reorder_pts) {
            frame->pts = frame->pkt_pts;
		} else {
            frame->pts = frame->pkt_dts;
		}
		
        if (frame->pts != AV_NOPTS_VALUE)
            dpts = av_q2d(is->video_st->time_base) * frame->pts;
        
        frame->sample_aspect_ratio = av_guess_sample_aspect_ratio(is->ic, is->video_st, frame);
        
        if (is->framedrop>0 || (is->framedrop && get_master_sync_type(is) != AV_SYNC_VIDEO_MASTER)) {
            if (frame->pts != AV_NOPTS_VALUE) {
                double diff = dpts - get_master_clock(is);
                if (!isnan(diff) && fabs(diff) < AV_NOSYNC_THRESHOLD &&
                    diff - is->frame_last_filter_delay < 0 &&
                    *serial == is->vidclk.serial &&
                    is->videoq.nb_packets) {
                    is->frame_drops_early++;
                    av_frame_unref(frame);
                    ret = 0;
                }
            }
        }
        
        return ret;
	}
	return 0;
}

int video_thread(void *arg)
{
    AVPacket pkt = { 0 };
	VideoState *is = arg;
	AVFrame *frame= av_frame_alloc();
	double pts;
    double duration;
	int ret;
    int serial = 0;
    AVRational tb = is->video_st->time_base;
    AVRational frame_rate = av_guess_frame_rate(is->ic, is->video_st, NULL);
	
	for(;;) {
        @autoreleasepool {
            while (is->paused && !is->videoq.abort_request)
                usleep(10*1000);
            
            av_frame_unref(frame);
            av_free_packet(&pkt);
            
            ret = get_video_frame(is, frame, &pkt, &serial);
            if (ret < 0) {
                goto the_end;
            }
            if (!ret)
                continue;
            
#if 0
#else
            duration = (frame_rate.num && frame_rate.den ? av_q2d((AVRational){frame_rate.den, frame_rate.num}) : 0);
            pts = (frame->pts == AV_NOPTS_VALUE) ? NAN : frame->pts * av_q2d(tb);
            ret = queue_picture(is, frame, pts, duration, av_frame_get_pkt_pos(frame), serial);
            av_frame_unref(frame);
#endif
            
            if (ret < 0)
                goto the_end;
        }
	}
the_end:
#if 0
#endif
    av_free_packet(&pkt);
    av_frame_free(&frame);
    
    /* LAVP: free up 420422 converter */
#if !ALLOW_GPL_CODE
	if (is->sws420to422) {
		sws_freeContext(is->sws420to422);
        is->sws420to422 = NULL;
    }
#endif
	return 0;
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
			if (vp->pts >= 0 && vp->pts == is->lastPTScopied) goto bail;
			
			LAVPUnlockMutex(is->pictq_mutex);
			return 1;
		} else {
			NSLog(@"ERROR: vp == NULL (%s)", __FUNCTION__);
		}
	} else {
		//NSLog(@"ERROR: is->pictq_size == 0 (%s)", __FUNCTION__);
	}
	
bail:
	LAVPUnlockMutex(is->pictq_mutex);
	return 0;
}

int copyImage(void *opaque, double_t *targetpts, uint8_t* data, int pitch) 
{
	VideoState *is = opaque;
	uint8_t * out[4] = {0};
	out[0] = data;
	assert(data);
	
#if !ALLOW_GPL_CODE
    /* LAVP: Prepare 420422 converter */
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
				
				if (0.0 <= tmp->pts && tmp->pts <= *targetpts) {
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
			
			if (vp->pts >= 0 && vp->pts == is->lastPTScopied) {
				LAVPUnlockMutex(is->pictq_mutex);
				return 2;
			}
			
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
		//NSLog(@"ERROR: is->pictq_size == 0 (%s)", __FUNCTION__);
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
			if (vp->pts >= 0 && vp->pts == is->lastPTScopied) goto bail;
			
			LAVPUnlockMutex(is->pictq_mutex);
			return 1;
		} else {
			NSLog(@"ERROR: vp == NULL (%s)", __FUNCTION__);
		}
	} else {
		//NSLog(@"ERROR: is->pictq_size == 0 (%s)", __FUNCTION__);
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
			
			if (vp->pts >= 0 && vp->pts == is->lastPTScopied) {
				LAVPUnlockMutex(is->pictq_mutex);
				return 2;
			}
			
            // TODO Add support to call blend_subrect() for subq (original:video_image_display())
            
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
		//NSLog(@"ERROR: is->pictq_size == 0 (%s)", __FUNCTION__);
	}
	
bail:
	LAVPUnlockMutex(is->pictq_mutex);
	return 0;
}
