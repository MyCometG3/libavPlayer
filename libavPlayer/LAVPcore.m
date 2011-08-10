/*
 *  LAVPcore.c
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
 along with xvidEncoder; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include "LAVPcore.h"
#include "LAVPvideo.h"
#include "LAVPqueue.h"
#include "LAVPsubs.h"
#include "LAVPaudio.h"

/* =========================================================== */

#define AUDIO_FRAME_SIZE 1024
#define MAX_QUEUE_SIZE (15 * 1024 * 1024)
#define MIN_AUDIOQ_SIZE (20 * 16 * 1024)
#define MIN_FRAMES 5 /*5*/

/* =========================================================== */

int stream_component_open(VideoState *is, int stream_index);
void stream_component_close(VideoState *is, int stream_index);
int decode_thread(void *arg);

double get_external_clock(VideoState *is);

/* =========================================================== */

#pragma mark -
#pragma mark functions (decode_thread)

// FIXME Should be thread local variable
//static VideoState *global_video_state;
//static int decode_interrupt_cb(void)
//{
//	return (global_video_state && global_video_state->abort_request);
//}

/* open a given stream. Return 0 if OK */
int stream_component_open(VideoState *is, int stream_index)
{
	AVFormatContext *ic = is->ic;
	AVCodecContext *avctx;
	AVCodec *codec;
	
	if (stream_index < 0 || stream_index >= ic->nb_streams)
		return -1;
	avctx = ic->streams[stream_index]->codec;
	
	/* prepare audio output */
	if (avctx->codec_type == AVMEDIA_TYPE_AUDIO) {
		if (avctx->channels > 0) {
			avctx->request_channels = FFMIN(2, avctx->channels);
		} else {
			avctx->request_channels = 2;
		}
	}
	
	codec = avcodec_find_decoder(avctx->codec_id);
	
	avctx->workaround_bugs = FF_BUG_AUTODETECT;
	avctx->idct_algo= FF_IDCT_AUTO;
	avctx->skip_frame= AVDISCARD_DEFAULT;
	avctx->skip_idct= AVDISCARD_DEFAULT;
	avctx->skip_loop_filter= AVDISCARD_DEFAULT;
	avctx->error_recognition= FF_ER_CAREFUL;
	avctx->error_concealment= FF_EC_DEBLOCK|FF_EC_GUESS_MVS;
	avctx->thread_count= 4;
	
	if (!codec ||
		avcodec_open2(avctx, codec, NULL) < 0)
		return -1;
	
	/* prepare audio output */
	if (avctx->codec_type == AVMEDIA_TYPE_AUDIO) {
		LAVPAudioQueueInit(is, avctx);
		is->audio_src_fmt= AV_SAMPLE_FMT_S16;
	}
	
	ic->streams[stream_index]->discard = AVDISCARD_DEFAULT;
	switch(avctx->codec_type) {
		case AVMEDIA_TYPE_AUDIO:
			is->audio_stream = stream_index;
			is->audio_st = ic->streams[stream_index];
			
			is->audio_buf_size = 0;
			is->audio_buf_index = 0;
			is->audio_diff_avg_coef = exp(log(0.01) / AUDIO_DIFF_AVG_NB);
			is->audio_diff_avg_count = 0;
			is->audio_diff_threshold = 2.0 * AUDIO_FRAME_SIZE / avctx->sample_rate;
			memset(&is->audio_pkt, 0, sizeof(is->audio_pkt));
			
			packet_queue_init(&is->audioq);
			
			LAVPAudioQueueStart(is);
			
			break;
		case AVMEDIA_TYPE_VIDEO:
			is->video_stream = stream_index;
			is->video_st = ic->streams[stream_index];
			
			packet_queue_init(&is->videoq);
			
			is->video_queue = dispatch_queue_create("video", NULL);
			is->video_group = dispatch_group_create();
			dispatch_group_async(is->video_group, is->video_queue, ^(void){video_thread(is);});
			break;
		case AVMEDIA_TYPE_SUBTITLE:
			is->subtitle_stream = stream_index;
			is->subtitle_st = ic->streams[stream_index];
			
			packet_queue_init(&is->subtitleq);
			
			is->video_queue = dispatch_queue_create("subtitle", NULL);
			is->subtitle_group = dispatch_group_create();
			dispatch_group_async(is->subtitle_group, is->subtitle_queue, ^(void){subtitle_thread(is);});
			break;
		default:
			break;
	}
	return 0;
}

void stream_component_close(VideoState *is, int stream_index)
{NSLog(@"stream_component_close(%d)", stream_index);
	AVFormatContext *ic = is->ic;
	AVCodecContext *avctx;
	
	if (stream_index < 0 || stream_index >= ic->nb_streams)
		return;
	avctx = ic->streams[stream_index]->codec;
	
	switch(avctx->codec_type) {
		case AVMEDIA_TYPE_AUDIO:
			packet_queue_abort(&is->audioq);
			
			LAVPAudioQueueStop(is);
			LAVPAudioQueueDealloc(is);
			
			packet_queue_end(&is->audioq);
			if (is->reformat_ctx)
				av_audio_convert_free(is->reformat_ctx);
			is->reformat_ctx = NULL;
			break;
		case AVMEDIA_TYPE_VIDEO:
			packet_queue_abort(&is->videoq);
			
			/* note: we also signal this mutex to make sure we deblock the
			 video thread in all cases */
			LAVPLockMutex(is->pictq_mutex);
			LAVPCondSignal(is->pictq_cond);
			LAVPUnlockMutex(is->pictq_mutex);
			
			dispatch_group_wait(is->video_group, DISPATCH_TIME_FOREVER);
			dispatch_release(is->video_group);
			dispatch_release(is->video_queue);
			
			packet_queue_end(&is->videoq);
			break;
		case AVMEDIA_TYPE_SUBTITLE:
			packet_queue_abort(&is->subtitleq);
			
			/* note: we also signal this mutex to make sure we deblock the
			 video thread in all cases */
			LAVPLockMutex(is->subpq_mutex);
			is->subtitle_stream_changed = 1;
			
			LAVPCondSignal(is->subpq_cond);
			LAVPUnlockMutex(is->subpq_mutex);
			
			dispatch_group_wait(is->subtitle_group, DISPATCH_TIME_FOREVER);
			dispatch_release(is->subtitle_group);
			dispatch_release(is->subtitle_queue);
			
			packet_queue_end(&is->subtitleq);
			break;
		default:
			break;
	}
	
	ic->streams[stream_index]->discard = AVDISCARD_ALL;
	avcodec_close(avctx);
	switch(avctx->codec_type) {
		case AVMEDIA_TYPE_AUDIO:
			is->audio_st = NULL;
			is->audio_stream = -1;
			break;
		case AVMEDIA_TYPE_VIDEO:
			is->video_st = NULL;
			is->video_stream = -1;
			break;
		case AVMEDIA_TYPE_SUBTITLE:
			is->subtitle_st = NULL;
			is->subtitle_stream = -1;
			break;
		default:
			break;
	}
}

int decode_thread(void *arg)
{
	int ret;
	VideoState *is = (VideoState *)arg;
	
	int st_index[AVMEDIA_TYPE_NB] = {-1};
	
	// Video and Audio
	st_index[AVMEDIA_TYPE_VIDEO] = av_find_best_stream(is->ic, AVMEDIA_TYPE_VIDEO, -1, 
													   -1, NULL, 0);
	st_index[AVMEDIA_TYPE_AUDIO] = av_find_best_stream(is->ic, AVMEDIA_TYPE_AUDIO, -1, 
													   st_index[AVMEDIA_TYPE_VIDEO], NULL , 0);
	// avio does not accept (void *)opaque
	//global_video_state = is;
	//avio_set_interrupt_cb(decode_interrupt_cb);
	
	/* Start each sub threads */
	if (st_index[AVMEDIA_TYPE_AUDIO] >= 0) 
		stream_component_open(is, st_index[AVMEDIA_TYPE_AUDIO]);
	
	if (st_index[AVMEDIA_TYPE_VIDEO] >= 0) 
		stream_component_open(is, st_index[AVMEDIA_TYPE_VIDEO]);
	
	if (is->video_stream < 0 && is->audio_stream < 0) {
		fprintf(stderr, "could not open codecs\n");
		ret = -1;
		goto bail;
	}
	
	// Subtitle
	int indexForSubs = (st_index[AVMEDIA_TYPE_AUDIO]>0 
						? st_index[AVMEDIA_TYPE_AUDIO] : st_index[AVMEDIA_TYPE_VIDEO]);
	st_index[AVMEDIA_TYPE_SUBTITLE] = av_find_best_stream(is->ic,AVMEDIA_TYPE_SUBTITLE, -1, 
														  indexForSubs, NULL , 0);
	
	/* Start subtitle thread */
	if (st_index[AVMEDIA_TYPE_SUBTITLE] >= 0) 
		stream_component_open(is, st_index[AVMEDIA_TYPE_SUBTITLE]);
	
	/* ================================================================================== */
	//NSLog(@"abort_request is %d", is->abort_request);
	
	// decode loop
	int eof=0;
	AVPacket pkt1;
	AVPacket *pkt = &pkt1;
	for(;;) {
		NSAutoreleasePool *pool = [NSAutoreleasePool new];
		
		// Abort
		if (is->abort_request) {
			[pool drain];
			break;
		}
		
		// Pause
		if (is->paused != is->last_paused) {
			is->last_paused = is->paused;
			if (is->paused)
				is->read_pause_return = av_read_pause(is->ic);
			else
				av_read_play(is->ic);
		}
#if CONFIG_RTSP_DEMUXER
		if (is->paused && !strcmp(ic->iformat->name, "rtsp")) {
			/* wait 10 ms to avoid trying to get another packet */
			/* XXX: horrible */
			usleep(10*1000);
			[pool drain];
			continue;
		}
#endif
		
		// Seek
		if (is->seek_req) {
			is->lastPTScopied = -1;
			int64_t seek_target= is->seek_pos;
			int64_t seek_min= is->seek_rel > 0 ? seek_target - is->seek_rel + 2: INT64_MIN;
			int64_t seek_max= is->seek_rel < 0 ? seek_target - is->seek_rel - 2: INT64_MAX;
			//FIXME the +-2 is due to rounding being not done in the correct direction in generation
			//      of the seek_pos/seek_rel variables
			
			ret = avformat_seek_file(is->ic, -1, seek_min, seek_target, seek_max, is->seek_flags);
			if (ret < 0) {
				fprintf(stderr, "%s: error while seeking\n", is->ic->filename);
			}else{
				if (is->audio_stream >= 0) {
					LAVPAudioQueueStop(is);
					packet_queue_flush(&is->audioq);
					packet_queue_put(&is->audioq, NULL);
					LAVPAudioQueueStart(is);
				}
				if (is->subtitle_stream >= 0) {
					packet_queue_flush(&is->subtitleq);
					packet_queue_put(&is->subtitleq, NULL);
				}
				if (is->video_stream >= 0) {
					packet_queue_flush(&is->videoq);
					packet_queue_put(&is->videoq, NULL);
				}
			}
			is->seek_req = 0;
			eof= 0;
		}
		
		// Check queue size
		if (   is->audioq.size + is->videoq.size + is->subtitleq.size > MAX_QUEUE_SIZE
			|| (   (is->audioq   .size  > MIN_AUDIOQ_SIZE || is->audio_stream<0)
				&& (is->videoq   .nb_packets > MIN_FRAMES || is->video_stream<0)
				&& (is->subtitleq.nb_packets > MIN_FRAMES || is->subtitle_stream<0))
			) {
			/* wait 10 ms */
			usleep(10*1000);
			[pool drain];
			continue;
		}
		
		// EOF reached
		if(eof) {
			if(is->video_stream >= 0){
				av_init_packet(pkt);
				pkt->data=NULL;
				pkt->size=0;
				pkt->stream_index= is->video_stream;
				packet_queue_put(&is->videoq, pkt);
			}
			usleep(10*1000);
			if(is->audioq.size + is->videoq.size + is->subtitleq.size ==0){
				//NSLog(@"End of packet detected.");
				if (is->loop > 1) {
					is->loop--;
					stream_seek(is, 0, 0, 0);
				}
			}
			[pool drain];
			continue;
		}
		
		// Read file
		ret = av_read_frame(is->ic, pkt);
		if (ret < 0) {
			if (ret == AVERROR_EOF || (is->ic->pb && is->ic->pb->eof_reached))
				eof=1;
			if (is->ic->pb && is->ic->pb->error) {
				[pool drain];
				break;
			}
			/* wait for user event */
			usleep(100*1000);
			[pool drain];
			continue;
		}
		
		// Queue packet
		if (pkt->stream_index == is->audio_stream) {
			packet_queue_put(&is->audioq, pkt);
			//NSLog(@"PUT : pkt->pts = %8lld, size = %8d, pos = %8lld ___PUT", pkt->pts, pkt->size, pkt->pos);
		} else if (pkt->stream_index == is->video_stream) {
			packet_queue_put(&is->videoq, pkt);
		} else if (pkt->stream_index == is->subtitle_stream) {
			packet_queue_put(&is->subtitleq, pkt);
		} else {
			av_free_packet(pkt);
		}
		
		[pool drain];
	}
	
	/* ================================================================================== */
	
	// wait sync
	while (!is->abort_request) {
		usleep(100*1000);
	}
	
	// finish thread
	ret = 0;
	
	//avio_set_interrupt_cb(NULL);
	
	/* close each stream */
	if (is->audio_stream >= 0)
		stream_component_close(is, is->audio_stream);
	if (is->video_stream >= 0)
		stream_component_close(is, is->video_stream);
	if (is->subtitle_stream >= 0)
		stream_component_close(is, is->subtitle_stream);
	
bail:
	return ret;
}

#pragma mark -
#pragma mark functions (main_thread)

/* get the current external clock value */
double get_external_clock(VideoState *is)
{
	int64_t ti;
	ti = av_gettime();
	return is->external_clock + ((ti - is->external_clock_time) * 1e-6);
}

/* get the current master clock value */
double get_master_clock(VideoState *is)
{
	double val;
	
	if (is->av_sync_type == AV_SYNC_VIDEO_MASTER) {
		if (is->video_st)
			val = get_video_clock(is);
		else
			val = get_audio_clock(is);
	} else if (is->av_sync_type == AV_SYNC_AUDIO_MASTER) {
		if (is->audio_st)
			val = get_audio_clock(is);
		else
			val = get_video_clock(is);
	} else {
		val = get_external_clock(is);
	}
	return val;
}

/* seek in the stream */
void stream_seek(VideoState *is, int64_t pos, int64_t rel, int seek_by_bytes)
{
	if (!is->seek_req) {
		is->seek_pos = pos;
		is->seek_rel = rel;
		is->seek_flags &= ~AVSEEK_FLAG_BYTE;
		if (seek_by_bytes)
			is->seek_flags |= AVSEEK_FLAG_BYTE;
		is->seek_req = 1;
	}
}

/* pause or resume the video */
void stream_pause(VideoState *is)
{
	if (is->paused) {
		is->frame_timer += av_gettime() / 1000000.0 + is->video_current_pts_drift - is->video_current_pts;
		if(is->read_pause_return != AVERROR(ENOSYS)){
			is->video_current_pts = is->video_current_pts_drift + av_gettime() / 1000000.0;
		}
		is->video_current_pts_drift = is->video_current_pts - av_gettime() / 1000000.0;
	}
	
	is->paused = !is->paused;
	is->step = 0;
	
	if (is->paused) 
		LAVPAudioQueueStop(is);
	else
		LAVPAudioQueueStart(is);
	
	NSLog(@"stream_pause = %s at %3.3f", (is->paused ? "paused" : "play"), get_master_clock(is));
}

void stream_close(VideoState *is)
{
	if (is) {
		VideoPicture *vp;
		int i;
		
		/* XXX: use a special url_shutdown call to abort parse cleanly */
		is->abort_request = 1;
		
		dispatch_group_wait(is->parse_group, DISPATCH_TIME_FOREVER);
		dispatch_release(is->parse_group);
		dispatch_release(is->parse_queue);
		
		//
		LAVPDestroyMutex(is->pictq_mutex);
		LAVPDestroyCond(is->pictq_cond);
		LAVPDestroyMutex(is->subpq_mutex);
		LAVPDestroyCond(is->subpq_cond);
		
		/* free all pictures */
		for(i=0;i<VIDEO_PICTURE_QUEUE_SIZE; i++) {
			vp = &is->pictq[i];
			if (vp->bmp) {
				avpicture_free((AVPicture*)vp->bmp);
				av_free(vp->bmp);
				vp->bmp = NULL;
			}
		}
		
		// free image converter
		if (is->img_convert_ctx)
			sws_freeContext(is->img_convert_ctx);
		
		// free format context
		av_close_input_file(is->ic);
		avformat_free_context(is->ic);
		is->ic = NULL;
		
		//
		free(is);
		is = NULL;
	}
}

VideoState* stream_open(id opaque, NSURL *sourceURL)
{
	int err;
	
	char* path = strdup([[sourceURL path] fileSystemRepresentation]);
	
	// Initialize VideoState struct
	VideoState *is = calloc(1, sizeof(VideoState));
	is->decoder = opaque;	// (LAVPDecoder *)
	is->loop = 1;
	is->paused = 0;
	//is->step = 1;
	//is->av_sync_type = AV_SYNC_VIDEO_MASTER;
	is->audio_stream = -1;
	is->video_stream = -1;
	is->subtitle_stream = -1;
	is->playRate = 1.0;
	
	// Prepare libav* contexts
	av_log_set_flags(AV_LOG_SKIP_REPEATED);
	av_register_all();//avcodec_register_all();
	
	// Open file
	err = avformat_open_input(&is->ic, path, NULL, NULL);
	if (err < 0) goto bail;
	
	// Prepare stream info
	err = avformat_find_stream_info(is->ic, NULL);
	if (err < 0) goto bail;
	
	if (is->ic->pb) 
		is->ic->pb->eof_reached = 0;
	
	is->seek_by_bytes = !!(is->ic->iformat->flags & AVFMT_TS_DISCONT);
	
	for (int i = 0; i < is->ic->nb_streams; i++)
		is->ic->streams[i]->discard = AVDISCARD_ALL;
	
	// dump format info
	if (is->show_status) {
		av_dump_format(is->ic, 0, path, 0);
	}
	
	{
		is->pictq_mutex = LAVPCreateMutex();
		is->pictq_cond = LAVPCreateCond();
		is->subpq_mutex = LAVPCreateMutex();
		is->subpq_cond = LAVPCreateCond();
	}
	
	is->parse_queue = dispatch_queue_create("parse", NULL);
	is->parse_group = dispatch_group_create();
	dispatch_group_async(is->parse_group, is->parse_queue, ^(void){decode_thread(is);});
	
	free(path);
	return is;
	
bail:
	fprintf(stderr, "err = %d\n", err);
	free(path);
	return NULL;
}

double_t stream_playRate(VideoState *is)
{
	return is->playRate;
}

void stream_setPlayRate(VideoState *is, double_t newRate)
{
	assert(newRate > 0.0 && newRate <= 4.0);
	
	is->playRate = newRate;
}
