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
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include "LAVPcore.h"
#include "LAVPvideo.h"
#include "LAVPqueue.h"
#include "LAVPsubs.h"
#include "LAVPaudio.h"

/* =========================================================== */

int stream_component_open(VideoState *is, int stream_index);
void stream_component_close(VideoState *is, int stream_index);
int is_realtime(AVFormatContext *s);
int read_thread(void *arg);
void step_to_next_frame(VideoState *is);

double get_external_clock(VideoState *is);

extern void free_picture(VideoPicture *vp);
extern void free_subpicture(SubPicture *sp);
extern int audio_open(void *opaque, int64_t wanted_channel_layout, int wanted_nb_channels, int wanted_sample_rate, struct AudioParams *audio_hw_params);

/* =========================================================== */

#pragma mark -
#pragma mark functions (cmdutils.c)

// extracted function from ffmpeg : cmdutils.c
int check_stream_specifier(AVFormatContext *s, AVStream *st, const char *spec)
{
    int ret = avformat_match_stream_specifier(s, st, spec);
    if (ret < 0)
        av_log(s, AV_LOG_ERROR, "Invalid stream specifier: %s.\n", spec);
    return ret;
}

// extracted function from ffmpeg : cmdutils.c
AVDictionary *filter_codec_opts(AVDictionary *opts, enum AVCodecID codec_id,
                                AVFormatContext *s, AVStream *st, AVCodec *codec)
{
    AVDictionary    *ret = NULL;
    AVDictionaryEntry *t = NULL;
    int            flags = s->oformat ? AV_OPT_FLAG_ENCODING_PARAM
    : AV_OPT_FLAG_DECODING_PARAM;
    char          prefix = 0;
    const AVClass    *cc = avcodec_get_class();
    
    if (!codec)
        codec            = s->oformat ? avcodec_find_encoder(codec_id)
        : avcodec_find_decoder(codec_id);
    
    switch (st->codec->codec_type) {
        case AVMEDIA_TYPE_VIDEO:
            prefix  = 'v';
            flags  |= AV_OPT_FLAG_VIDEO_PARAM;
            break;
        case AVMEDIA_TYPE_AUDIO:
            prefix  = 'a';
            flags  |= AV_OPT_FLAG_AUDIO_PARAM;
            break;
        case AVMEDIA_TYPE_SUBTITLE:
            prefix  = 's';
            flags  |= AV_OPT_FLAG_SUBTITLE_PARAM;
            break;
        default:
            break;
    }
    
    while ((t = av_dict_get(opts, "", t, AV_DICT_IGNORE_SUFFIX))) {
        char *p = strchr(t->key, ':');
        
        /* check stream specification in opt name */
        if (p)
            switch (check_stream_specifier(s, st, p + 1)) {
                case  1: *p = 0; break;
                case  0:         continue;
                default:         return NULL;
            }
        
        if (av_opt_find(&cc, t->key, NULL, flags, AV_OPT_SEARCH_FAKE_OBJ) ||
            (codec && codec->priv_class &&
             av_opt_find(&codec->priv_class, t->key, NULL, flags,
                         AV_OPT_SEARCH_FAKE_OBJ)))
            av_dict_set(&ret, t->key, t->value, 0);
        else if (t->key[0] == prefix &&
                 av_opt_find(&cc, t->key + 1, NULL, flags,
                             AV_OPT_SEARCH_FAKE_OBJ))
            av_dict_set(&ret, t->key + 1, t->value, 0);
        
        if (p)
            *p = ':';
    }
    return ret;
}

// extracted function from ffmpeg : cmdutils.c
AVDictionary **setup_find_stream_info_opts(AVFormatContext *s,
                                           AVDictionary *codec_opts)
{
    int i;
    AVDictionary **opts;
    
    if (!s->nb_streams)
        return NULL;
    opts = av_mallocz(s->nb_streams * sizeof(*opts));
    if (!opts) {
        av_log(NULL, AV_LOG_ERROR,
               "Could not alloc memory for stream options.\n");
        return NULL;
    }
    for (i = 0; i < s->nb_streams; i++)
        opts[i] = filter_codec_opts(codec_opts, s->streams[i]->codec->codec_id,
                                    s, s->streams[i], NULL);
    return opts;
}

#pragma mark -
#pragma mark functions (read_thread)

/* open a given stream. Return 0 if OK */
int stream_component_open(VideoState *is, int stream_index)
{
	//NSLog(@"DEBUG: stream_component_open(%d)", stream_index);
	
	AVFormatContext *ic = is->ic;
	AVCodecContext *avctx;
	AVCodec *codec;
    const char *forced_codec_name = NULL;
    AVDictionary *opts;
    AVDictionaryEntry *t = NULL;
    int sample_rate, nb_channels;
    int64_t channel_layout;
    int ret;
    int stream_lowres = is->lowres;
    
	if (stream_index < 0 || stream_index >= ic->nb_streams)
		return -1;
	avctx = ic->streams[stream_index]->codec;
	
	codec = avcodec_find_decoder(avctx->codec_id);
	
    //
    if (forced_codec_name)
        codec = avcodec_find_decoder_by_name(forced_codec_name);
	if (!codec) {
        if (forced_codec_name) av_log(NULL, AV_LOG_WARNING,
                                      "No codec could be found with name '%s'\n", forced_codec_name);
        else                   av_log(NULL, AV_LOG_WARNING,
                                      "No codec could be found with id %d\n", avctx->codec_id);
		return -1;
    }
    
    avctx->codec_id = codec->id;
	avctx->workaround_bugs = is->workaround_bugs;
    if(stream_lowres > av_codec_get_max_lowres(codec)){
        av_log(avctx, AV_LOG_WARNING, "The maximum value for lowres supported by the decoder is %d\n",
               av_codec_get_max_lowres(codec));
        stream_lowres = av_codec_get_max_lowres(codec);
    }
    av_codec_set_lowres(avctx, stream_lowres);
	avctx->error_concealment= is->error_concealment;
	
    if(stream_lowres) avctx->flags |= CODEC_FLAG_EMU_EDGE;
    if (is->fast)   avctx->flags2 |= CODEC_FLAG2_FAST;
    if(codec->capabilities & CODEC_CAP_DR1)
        avctx->flags |= CODEC_FLAG_EMU_EDGE;
    
    AVDictionary *codec_opts = NULL; // LAVP: Dummy
    
    opts = filter_codec_opts(codec_opts, avctx->codec_id, ic, ic->streams[stream_index], codec);
    if (!av_dict_get(opts, "threads", NULL, 0))
        av_dict_set(&opts, "threads", "auto", 0);
    if (stream_lowres)
        av_dict_set(&opts, "lowres", av_asprintf("%d", stream_lowres), AV_DICT_DONT_STRDUP_VAL);
    if (avctx->codec_type == AVMEDIA_TYPE_VIDEO || avctx->codec_type == AVMEDIA_TYPE_AUDIO)
        av_dict_set(&opts, "refcounted_frames", "1", 0);
    if (avcodec_open2(avctx, codec, &opts) < 0)
        return -1;
    if ((t = av_dict_get(opts, "", NULL, AV_DICT_IGNORE_SUFFIX))) {
        av_log(NULL, AV_LOG_ERROR, "Option %s not found.\n", t->key);
        return AVERROR_OPTION_NOT_FOUND;
    }
    
	ic->streams[stream_index]->discard = AVDISCARD_DEFAULT;
    switch (avctx->codec_type) {
		case AVMEDIA_TYPE_AUDIO:
            // LAVP: set before audio_open
			is->audio_stream = stream_index;
			is->audio_st = ic->streams[stream_index];
			
            packet_queue_start(&is->audioq);
			
            //
            sample_rate    = avctx->sample_rate;
            nb_channels    = avctx->channels;
            channel_layout = avctx->channel_layout;
            
            /* prepare audio output */
            if ((ret = audio_open(is, channel_layout, nb_channels, sample_rate, &is->audio_tgt)) < 0)
                return ret;
            is->audio_hw_buf_size = ret;
            is->audio_src = is->audio_tgt;
            is->audio_buf_size  = 0;
            is->audio_buf_index = 0;
            
            /* init averaging filter */
			is->audio_diff_avg_coef = exp(log(0.01) / AUDIO_DIFF_AVG_NB);
			is->audio_diff_avg_count = 0;
            /* since we do not have a precise anough audio fifo fullness,
             we correct audio sync only if larger than this threshold */
			is->audio_diff_threshold = 2.0 * is->audio_hw_buf_size / av_samples_get_buffer_size(NULL, is->audio_tgt.channels, is->audio_tgt.freq, is->audio_tgt.fmt, 1);

            memset(&is->audio_pkt, 0, sizeof(is->audio_pkt));
            memset(&is->audio_pkt_temp, 0, sizeof(is->audio_pkt_temp));
            is->audio_pkt_temp.stream_index = -1;
			
            // LAVP: start AudioQueue
            LAVPAudioQueueInit(is, avctx);
			LAVPAudioQueueStart(is);
			
			break;
		case AVMEDIA_TYPE_VIDEO:
			is->video_stream = stream_index;
			is->video_st = ic->streams[stream_index];
			
            packet_queue_start(&is->videoq);
			
            // LAVP: Using dispatch queue
            {
                dispatch_queue_t video_queue = dispatch_queue_create("video", NULL);
                dispatch_group_t video_group = dispatch_group_create();
                is->video_queue = (__bridge_retained void*)video_queue;
                is->video_group = (__bridge_retained void*)video_group;
            }
            dispatch_group_async((__bridge dispatch_group_t)is->video_group, (__bridge dispatch_queue_t)is->video_queue, ^(void){video_thread(is);});
            is->queue_attachments_req = 1;
			break;
		case AVMEDIA_TYPE_SUBTITLE:
			is->subtitle_stream = stream_index;
			is->subtitle_st = ic->streams[stream_index];
			
            packet_queue_start(&is->subtitleq);
			
            // LAVP: Using dispatch queue
            {
                dispatch_queue_t subtitle_queue = dispatch_queue_create("subtitle", NULL);
                dispatch_group_t subtitle_group = dispatch_group_create();
                is->subtitle_queue = (__bridge_retained void*)subtitle_queue;
                is->subtitle_group = (__bridge_retained void*)subtitle_group;
            }
			dispatch_group_async((__bridge dispatch_group_t)is->subtitle_group, (__bridge dispatch_queue_t)is->subtitle_queue, ^(void){subtitle_thread(is);});
			break;
		default:
			break;
	}
    
	//NSLog(@"DEBUG: stream_component_open(%d) done", stream_index);
	return 0;
}

void stream_component_close(VideoState *is, int stream_index)
{
	//NSLog(@"DEBUG: stream_component_close(%d)", stream_index);
	
	AVFormatContext *ic = is->ic;
	AVCodecContext *avctx;
	
	if (stream_index < 0 || stream_index >= ic->nb_streams)
		return;
	avctx = ic->streams[stream_index]->codec;
	
	switch(avctx->codec_type) {
		case AVMEDIA_TYPE_AUDIO:
			packet_queue_abort(&is->audioq);
			
            // LAVP: Stop Audio Queue
			LAVPAudioQueueStop(is);
			LAVPAudioQueueDealloc(is);
			
            //
			packet_queue_flush(&is->audioq);
			av_free_packet(&is->audio_pkt);
            swr_free(&is->swr_ctx);
            av_freep(&is->audio_buf1);
            is->audio_buf1_size = 0;
            is->audio_buf = NULL;
            av_frame_free(&is->frame);
            
            if (is->rdft) {
                av_rdft_end(is->rdft);
                av_freep(&is->rdft_data);
                is->rdft = NULL;
                is->rdft_bits = 0;
            }
#if 0
            // LAVP:
#endif
			break;
		case AVMEDIA_TYPE_VIDEO:
			packet_queue_abort(&is->videoq);
			
			/* note: we also signal this mutex to make sure we deblock the
			 video thread in all cases */
			LAVPLockMutex(is->pictq_mutex);
			LAVPCondSignal(is->pictq_cond);
			LAVPUnlockMutex(is->pictq_mutex);
			
            // LAVP: release dispatch queue
			dispatch_group_wait((__bridge dispatch_group_t)is->video_group, DISPATCH_TIME_FOREVER);
            {
                dispatch_group_t video_group = (__bridge_transfer dispatch_group_t)is->video_group;
                dispatch_queue_t video_queue = (__bridge_transfer dispatch_queue_t)is->video_queue;
                video_group = NULL; // ARC
                video_queue = NULL; // ARC
                is->video_group = NULL;
                is->video_queue = NULL;
            }
			packet_queue_flush(&is->videoq);
			break;
		case AVMEDIA_TYPE_SUBTITLE:
			packet_queue_abort(&is->subtitleq);
			
			/* note: we also signal this mutex to make sure we deblock the
			 video thread in all cases */
			LAVPLockMutex(is->subpq_mutex);
			LAVPCondSignal(is->subpq_cond);
			LAVPUnlockMutex(is->subpq_mutex);
			
            // LAVP: release dispatch queue
			dispatch_group_wait((__bridge dispatch_group_t)is->subtitle_group, DISPATCH_TIME_FOREVER);
            {
                dispatch_group_t subtitle_group = (__bridge_transfer dispatch_group_t)is->subtitle_group;
                dispatch_queue_t subtitle_queue = (__bridge_transfer dispatch_queue_t)is->subtitle_queue;
                subtitle_group = NULL; // ARC
                subtitle_queue = NULL; // ARC
                is->subtitle_group = NULL;
                is->subtitle_queue = NULL;
            }
			packet_queue_flush(&is->subtitleq);
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
    
	//NSLog(@"DEBUG: stream_component_close(%d) done", stream_index);
}

static int decode_interrupt_cb(void *ctx)
{
    VideoState *is = ctx;
    return is->abort_request;
}

int is_realtime(AVFormatContext *s)
{
    if(   !strcmp(s->iformat->name, "rtp")
       || !strcmp(s->iformat->name, "rtsp")
       || !strcmp(s->iformat->name, "sdp")
       )
        return 1;
    
    if(s->pb && (   !strncmp(s->filename, "rtp:", 4)
                 || !strncmp(s->filename, "udp:", 4)
                 )
       )
        return 1;
    return 0;
}

/* this thread gets the stream from the disk or the network */
int read_thread(void *arg)
{
    @autoreleasepool {
        
        int ret;
        VideoState *is = (VideoState *)arg;
        
        int st_index[AVMEDIA_TYPE_NB] = {-1};
        
        LAVPmutex* wait_mutex = LAVPCreateMutex();
        
        // LAVP: Choose best stream for Video, Audio, Subtitle
        int vid_index = -1;
        int aud_index = (st_index[AVMEDIA_TYPE_VIDEO]);
        int sub_index = (st_index[AVMEDIA_TYPE_AUDIO] >= 0 ? st_index[AVMEDIA_TYPE_AUDIO] : st_index[AVMEDIA_TYPE_VIDEO]);
        
        st_index[AVMEDIA_TYPE_VIDEO] = av_find_best_stream(is->ic, AVMEDIA_TYPE_VIDEO, -1, vid_index, NULL, 0);
        st_index[AVMEDIA_TYPE_AUDIO] = av_find_best_stream(is->ic, AVMEDIA_TYPE_AUDIO, -1,  aud_index, NULL , 0);
        st_index[AVMEDIA_TYPE_SUBTITLE] = av_find_best_stream(is->ic, AVMEDIA_TYPE_SUBTITLE, -1, sub_index , NULL, 0);
        
        // LAVP: show_status is in stream_open()
        
        /* open the streams */
        if (st_index[AVMEDIA_TYPE_AUDIO] >= 0)
            stream_component_open(is, st_index[AVMEDIA_TYPE_AUDIO]);
        
        ret = -1;
        if (st_index[AVMEDIA_TYPE_VIDEO] >= 0)
            ret = stream_component_open(is, st_index[AVMEDIA_TYPE_VIDEO]);
        
        if (is->show_mode == SHOW_MODE_NONE)
            is->show_mode = ret >= 0 ? SHOW_MODE_VIDEO : SHOW_MODE_RDFT;
        
        if (st_index[AVMEDIA_TYPE_SUBTITLE] >= 0)
            stream_component_open(is, st_index[AVMEDIA_TYPE_SUBTITLE]);
        
        if (is->video_stream < 0 && is->audio_stream < 0) {
            av_log(NULL, AV_LOG_FATAL, "Failed to open file '%s' or configure filtergraph\n",
                   is->filename);
            ret = -1;
            goto bail;
        }
        
        if (is->infinite_buffer < 0 && is->realtime)
            is->infinite_buffer = 1;
        
        /* ================================================================================== */
        
        // decode loop
        is->eof_flag = 0; // LAVP:
        int eof = 0;
        AVPacket pkt1, *pkt = &pkt1;
        for(;;) {
            @autoreleasepool {
                // Abort
                if (is->abort_request) {
                    break;
                }
                
                // Pause
                if (is->paused != is->last_paused) {
                    is->last_paused = is->paused;
                    if (is->paused)
                        is->read_pause_return = av_read_pause(is->ic);
                    else
                        av_read_play(is->ic);
                    
                    //NSLog(@"DEBUG: %@", is->paused ? @"paused:YES" : @"paused:NO");
                }
                
#if CONFIG_RTSP_DEMUXER
                if (is->paused &&
                    (!strcmp(is->ic->iformat->name, "rtsp") ||
                     (is->ic->pb && !strncmp(input_filename, "mmsh:", 5)))) {
                        /* wait 10 ms to avoid trying to get another packet */
                        /* XXX: horrible */
                        usleep(10*1000);
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
                        av_log(NULL, AV_LOG_ERROR,
                               "%s: error while seeking\n", is->ic->filename);
                    }else{
                        if (is->audio_stream >= 0) {
                            packet_queue_flush(&is->audioq);
                            packet_queue_put(&is->audioq, NULL);
                        }
                        if (is->subtitle_stream >= 0) {
                            packet_queue_flush(&is->subtitleq);
                            packet_queue_put(&is->subtitleq, NULL);
                        }
                        if (is->video_stream >= 0) {
                            packet_queue_flush(&is->videoq);
                            packet_queue_put(&is->videoq, NULL);
                        }
                        if (is->seek_flags & AVSEEK_FLAG_BYTE) {
                            set_clock(&is->extclk, NAN, 0);
                        } else {
                            set_clock(&is->extclk, seek_target / (double)AV_TIME_BASE, 0);
                        }
                    }
                    is->seek_req = 0;
                    is->queue_attachments_req = 1;
                    eof = 0;
                    
                    // LAVP: reset eof (referenced from LAVPDecoder)
                    is->eof_flag = 0;
                    
                    if (is->paused)
                        step_to_next_frame(is);
                }
                
                if (is->queue_attachments_req) {
                    if (is->video_st && is->video_st->disposition & AV_DISPOSITION_ATTACHED_PIC) {
                        AVPacket copy;
                        if ((ret = av_copy_packet(&copy, &is->video_st->attached_pic)) < 0)
                            goto bail;
                        packet_queue_put(&is->videoq, &copy);
                        packet_queue_put_nullpacket(&is->videoq, is->video_stream);
                    }
                    is->queue_attachments_req = 0;
                }
                
                /* if the queue are full, no need to read more */
                if (is->infinite_buffer<1 &&
                    (is->audioq.size + is->videoq.size + is->subtitleq.size > MAX_QUEUE_SIZE
                     || (   (is->audioq   .nb_packets > MIN_FRAMES || is->audio_stream < 0 || is->audioq.abort_request)
                         && (is->videoq   .nb_packets > MIN_FRAMES || is->video_stream < 0 || is->videoq.abort_request
                             || (is->video_st && is->video_st->disposition & AV_DISPOSITION_ATTACHED_PIC))
                         && (is->subtitleq.nb_packets > MIN_FRAMES || is->subtitle_stream < 0 || is->subtitleq.abort_request)))) {
                         /* wait 10 ms */
                         LAVPLockMutex(wait_mutex);
                         LAVPCondWaitTimeout(is->continue_read_thread, wait_mutex, 10);
                         LAVPUnlockMutex(wait_mutex);
                         continue;
                     }
                
                // LAVP: EOF reached
                if (is->eof_flag) {
                    usleep(50*1000);
                    continue;
                }
                if (!is->paused &&
                    (!is->audio_st || is->audio_finished == is->audioq.serial) &&
                    (!is->video_st || (is->video_finished == is->videoq.serial && is->pictq_size == 0))) {
                    // LAVP: force stream paused on EOF
                    stream_pause(is);
                    
                    // LAVP: finally mark end of stream flag (reset when seek performed)
                    is->eof_flag = 1;
                    
                    //NSLog(@"DEBUG: eof_flag = 1 on %f", get_master_clock(is));
                }
                if(eof) {
                    if (is->video_stream >= 0)
                        packet_queue_put_nullpacket(&is->videoq, is->video_stream);
                    if (is->audio_stream >= 0)
                        packet_queue_put_nullpacket(&is->audioq, is->audio_stream);
                    usleep(10*1000);
                    eof=0;
                    continue;
                }
                
                // Read file
                ret = av_read_frame(is->ic, pkt);
                if (ret < 0) {
                    if (ret == AVERROR_EOF || url_feof(is->ic->pb))
                        eof=1;
                    if (is->ic->pb && is->ic->pb->error) {
                        break;
                    }
                    LAVPLockMutex(wait_mutex);
                    LAVPCondWaitTimeout(is->continue_read_thread, wait_mutex, 10);
                    LAVPUnlockMutex(wait_mutex);
                    continue;
                }
                
                // Queue packet
                int64_t start_time = AV_NOPTS_VALUE; // LAVP:
                int64_t duration = AV_NOPTS_VALUE; // LAVP:
                int64_t stream_start_time; // LAVP:
                int pkt_in_play_range; // LAVP:
                
                /* check if packet is in play range specified by user, then queue, otherwise discard */
                stream_start_time = is->ic->streams[pkt->stream_index]->start_time; // LAVP:
                pkt_in_play_range = duration == AV_NOPTS_VALUE ||
                (pkt->pts - (stream_start_time != AV_NOPTS_VALUE ? stream_start_time : 0)) *
                av_q2d(is->ic->streams[pkt->stream_index]->time_base) -
                (double)(start_time != AV_NOPTS_VALUE ? start_time : 0) / 1000000
                <= ((double)duration / 1000000);
                if (pkt->stream_index == is->audio_stream && pkt_in_play_range) {
                    packet_queue_put(&is->audioq, pkt);
                } else if (pkt->stream_index == is->video_stream && pkt_in_play_range && !(is->video_st && is->video_st->disposition & AV_DISPOSITION_ATTACHED_PIC)) {
                    packet_queue_put(&is->videoq, pkt);
                } else if (pkt->stream_index == is->subtitle_stream && pkt_in_play_range) {
                    packet_queue_put(&is->subtitleq, pkt);
                } else {
                    av_free_packet(pkt);
                }
                
            }
        }
        
        /* ================================================================================== */
        
        /* wait until the end */
        while (!is->abort_request) {
            usleep(10*1000);
        }
        
        // finish thread
        ret = 0;
        
    bail:
        /* close each stream */
        if (is->audio_stream >= 0)
            stream_component_close(is, is->audio_stream);
        if (is->video_stream >= 0)
            stream_component_close(is, is->video_stream);
        if (is->subtitle_stream >= 0)
            stream_component_close(is, is->subtitle_stream);
        
        LAVPDestroyMutex(wait_mutex);
        
        return ret;
    }
}

#pragma mark -
#pragma mark functions (main_thread)


static int lockmgr(void **mtx, enum AVLockOp op)
{
    switch(op) {
        case AV_LOCK_CREATE:
            *mtx = LAVPCreateMutex();
            if(!*mtx)
                return 1;
            return 0;
        case AV_LOCK_OBTAIN:
            LAVPLockMutex(*mtx);
            return 0;
        case AV_LOCK_RELEASE:
            LAVPUnlockMutex(*mtx);
            return 0;
        case AV_LOCK_DESTROY:
            LAVPDestroyMutex(*mtx);
            return 0;
    }
    return 1;
}

double get_clock(Clock *c)
{
    if (*c->queue_serial != c->serial)
        return NAN;
    if (c->paused) {
        return c->pts;
    } else {
        double time = av_gettime() / 1000000.0;
        return c->pts_drift + time - (time - c->last_updated) * (1.0 - c->speed);
    }
}

void set_clock_at(Clock *c, double pts, int serial, double time)
{
    c->pts = pts;
    c->last_updated = time;
    c->pts_drift = c->pts - time;
    c->serial = serial;
}

void set_clock(Clock *c, double pts, int serial)
{
    double time = av_gettime() / 1000000.0;
    set_clock_at(c, pts, serial, time);
}

void set_clock_speed(Clock *c, double speed)
{
    set_clock(c, get_clock(c), c->serial);
    c->speed = speed;
}

void init_clock(Clock *c, volatile int *queue_serial)
{
    c->speed = 1.0;
    c->paused = 0;
    c->queue_serial = queue_serial;
    set_clock(c, NAN, -1);
}

void sync_clock_to_slave(Clock *c, Clock *slave)
{
    double clock = get_clock(c);
    double slave_clock = get_clock(slave);
    if (!isnan(slave_clock) && (isnan(clock) || fabs(clock - slave_clock) > AV_NOSYNC_THRESHOLD))
        set_clock(c, slave_clock, slave->serial);
}

int get_master_sync_type(VideoState *is) {
    if (is->av_sync_type == AV_SYNC_VIDEO_MASTER) {
        if (is->video_st)
            return AV_SYNC_VIDEO_MASTER;
        else
            return AV_SYNC_AUDIO_MASTER;
    } else if (is->av_sync_type == AV_SYNC_AUDIO_MASTER) {
        if (is->audio_st)
            return AV_SYNC_AUDIO_MASTER;
        else
            return AV_SYNC_EXTERNAL_CLOCK;
    } else {
        return AV_SYNC_EXTERNAL_CLOCK;
    }
}

/* get the current master clock value */
double get_master_clock(VideoState *is)
{
	//NSLog(@"DEBUG: vidclk:%8.3f audclk:%8.3f", (double_t)get_clock(&is->vidclk), (double_t)get_clock(&is->audclk));
    
	double val;
    switch (get_master_sync_type(is)) {
        case AV_SYNC_VIDEO_MASTER:
            val = get_clock(&is->vidclk);
            break;
        case AV_SYNC_AUDIO_MASTER:
            val = get_clock(&is->audclk);
            break;
        default:
            val = get_clock(&is->extclk);
            break;
    }
	return val;
}

void check_external_clock_speed(VideoState *is) {
    if ((is->video_stream >= 0 && is->videoq.nb_packets <= MIN_FRAMES / 2) ||
        (is->audio_stream >= 0 && is->audioq.nb_packets <= MIN_FRAMES / 2)) {
        set_clock_speed(&is->extclk, FFMAX(EXTERNAL_CLOCK_SPEED_MIN, is->extclk.speed - EXTERNAL_CLOCK_SPEED_STEP));
    } else if ((is->video_stream < 0 || is->videoq.nb_packets > MIN_FRAMES * 2) &&
               (is->audio_stream < 0 || is->audioq.nb_packets > MIN_FRAMES * 2)) {
        set_clock_speed(&is->extclk, FFMIN(EXTERNAL_CLOCK_SPEED_MAX, is->extclk.speed + EXTERNAL_CLOCK_SPEED_STEP));
    } else {
        double speed = is->extclk.speed;
        if (speed != 1.0)
            set_clock_speed(&is->extclk, speed + EXTERNAL_CLOCK_SPEED_STEP * (1.0 - speed) / fabs(1.0 - speed));
    }
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

        is->remaining_time = 0.0; // LAVP: reset remaining time
        
        LAVPCondSignal(is->continue_read_thread);
	}
}

/* pause or resume the video */
void stream_toggle_pause(VideoState *is)
{
    if (is->paused) {
        is->frame_timer += av_gettime() / 1000000.0 + is->vidclk.pts_drift - is->vidclk.pts;
        if (is->read_pause_return != AVERROR(ENOSYS)) {
            is->vidclk.paused = 0;
        }
        set_clock(&is->vidclk, get_clock(&is->vidclk), is->vidclk.serial);
    }
    set_clock(&is->extclk, get_clock(&is->extclk), is->extclk.serial);
    is->paused = is->audclk.paused = is->vidclk.paused = is->extclk.paused = !is->paused;
}

void toggle_pause(VideoState *is)
{
    stream_toggle_pause(is);
    is->step = 0;
}

void step_to_next_frame(VideoState *is)
{
    /* if the stream is paused unpause it, then step */
    if (is->paused)
        stream_toggle_pause(is);
    is->step = 1;
}

/* pause or resume the video */
void stream_pause(VideoState *is)
{
    toggle_pause(is);
	
	if (is->audio_stream >= 0) {
		if (is->paused) 
			LAVPAudioQueuePause(is);
		else
			LAVPAudioQueueStart(is);
	}
	
	//NSLog(@"DEBUG: stream_pause = %s at %3.3f", (is->paused ? "paused" : "play"), get_master_clock(is));
}

void stream_close(VideoState *is)
{
    /* original: stream_close() */
	if (is) {
		int i;
		
		/* XXX: use a special url_shutdown call to abort parse cleanly */
		is->abort_request = 1;
        
		dispatch_group_wait((__bridge dispatch_group_t)is->parse_group, DISPATCH_TIME_FOREVER);
        {
            dispatch_group_t parse_group = (__bridge_transfer dispatch_group_t)is->parse_group;
            dispatch_queue_t parse_queue = (__bridge_transfer dispatch_queue_t)is->parse_queue;
            parse_group = NULL; // ARC
            parse_queue = NULL; // ARC
            is->parse_group = NULL;
            is->parse_queue = NULL;
        }
        //
        packet_queue_destroy(&is->videoq);
        packet_queue_destroy(&is->audioq);
        packet_queue_destroy(&is->subtitleq);

		/* free all pictures */
        for (i = 0; i < VIDEO_PICTURE_QUEUE_SIZE; i++)
            free_picture(&is->pictq[i]);
        for (i = 0; i < SUBPICTURE_QUEUE_SIZE; i++)
            free_subpicture(&is->subpq[i]);
		
		//
		LAVPDestroyMutex(is->pictq_mutex);
		LAVPDestroyCond(is->pictq_cond);
		LAVPDestroyMutex(is->subpq_mutex);
		LAVPDestroyCond(is->subpq_cond);
		LAVPDestroyCond(is->continue_read_thread);

		// LAVP: free image converter
		if (is->img_convert_ctx)
			sws_freeContext(is->img_convert_ctx);
		
		// LAVP: free format context
        if (is->ic) {
            avformat_close_input(&is->ic);
            is->ic = NULL;
        }
        
        {
            id decoder = (__bridge_transfer id)is->decoder;
            decoder = NULL; // ARC
            is->decoder = NULL;
        }
    }
    
    /* original: do_exit() */
    BOOL doLF = false;
    if (is) {
        doLF = (is->show_status);
        
		free(is);
		is = NULL;
	}
    av_lockmgr_register(NULL);
    //
    avformat_network_deinit();
    if (doLF)
        printf("\n");
    av_log(NULL, AV_LOG_QUIET, "%s", "");
}

VideoState* stream_open(id opaque, NSURL *sourceURL)
{
    int err, i, ret;
	
	// Initialize VideoState struct
	VideoState *is = calloc(1, sizeof(VideoState));
    assert(is);
	
	const char* path = [[sourceURL path] fileSystemRepresentation];
    if (path) {
        is->filename = strdup(path);
    }
    
    /* ======================================== */
	
	is->decoder = (__bridge_retained void*)opaque;	// (LAVPDecoder *)
	is->lastPTScopied = -1;
    	
    is->sws_flags = SWS_BICUBIC;
    is->seek_by_bytes = -1;
    is->display_disable = 0;
#if 0 // LAVP:
    is->show_status = -1;
#endif
    is->workaround_bugs = 1;
    is->fast = 0;
    is->genpts = 0;
    is->lowres = 0;
    is->error_concealment = 3;
    is->decoder_reorder_pts = -1;
    is->loop = 1;
    is->framedrop = -1;
	is->infinite_buffer = -1;
    is->show_mode = SHOW_MODE_NONE;
    is->rdftspeed = 0.02;
    
	is->paused = 0;
	is->playRate = 1.0;

    is->last_video_stream = is->video_stream = -1;
    is->last_audio_stream = is->audio_stream = -1;
    is->last_subtitle_stream = is->subtitle_stream = -1;
    
    /* ======================================== */
	
    /* original: main() */
    {
        av_log_set_flags(AV_LOG_SKIP_REPEATED);
        
        /* register all codecs, demux and protocols */
        av_register_all();
        avformat_network_init();
        
        //
        if (av_lockmgr_register(lockmgr)) {
            av_log(NULL, AV_LOG_FATAL, "Could not initialize lock manager!\n");
            goto bail;
        }
    }
    
    /* ======================================== */
	
    /* original: opt_format() */
    // TODO
    const char * extension = [[sourceURL pathExtension] cStringUsingEncoding:NSASCIIStringEncoding];

    // LAVP: Guess file format
    if (extension) {
        AVInputFormat *file_iformat = av_find_input_format(extension);
        if (file_iformat) {
            is->iformat = file_iformat;
        }
    }
    
    /* ======================================== */
	
    /* original: read_thread() */
	// Open file
    {
        AVFormatContext *ic = NULL;
        AVDictionaryEntry *t = NULL;
        AVDictionary *format_opts = NULL; // LAVP: difine as local value
        
        ic = avformat_alloc_context();
        ic->interrupt_callback.callback = decode_interrupt_cb;
        ic->interrupt_callback.opaque = is;
        err = avformat_open_input(&ic, is->filename, is->iformat, &format_opts);
        if (err < 0) {
            // LAVP: inline for print_error(is->filename, err);
            {
                char errbuf[128];
                const char *errbuf_ptr = errbuf;
                
                if (av_strerror(err, errbuf, sizeof(errbuf)) < 0)
                    errbuf_ptr = strerror(AVUNERROR(err));
                av_log(NULL, AV_LOG_ERROR, "%s: %s\n", is->filename, errbuf_ptr);
            }
            ret = -1;
            goto bail;
        }
        if ((t = av_dict_get(format_opts, "", NULL, AV_DICT_IGNORE_SUFFIX))) {
            av_log(NULL, AV_LOG_ERROR, "Option %s not found.\n", t->key);
            ret = AVERROR_OPTION_NOT_FOUND;
            goto bail;
        }
        is->ic = ic;
    }
    
    if (is->genpts)
        is->ic->flags |= AVFMT_FLAG_GENPTS;
	
	// Examine stream info
    {
        AVDictionary **opts;
        AVDictionary *codec_opts = NULL; // LAVP: Dummy
        int orig_nb_streams;
        
        opts = setup_find_stream_info_opts(is->ic, codec_opts);
        orig_nb_streams = is->ic->nb_streams;
        
        err = avformat_find_stream_info(is->ic, opts);
        if (err < 0) {
            av_log(NULL, AV_LOG_WARNING,
                   "%s: could not find codec parameters\n", is->filename);
            ret = -1;
            goto bail;
        }
    
        for (i = 0; i < orig_nb_streams; i++)
            av_dict_free(&opts[i]);
        av_freep(&opts);
	}
    
	if (is->ic->pb) 
        is->ic->pb->eof_reached = 0; // FIXME hack, ffplay maybe should not use url_feof() to test for the end
	
    if (is->seek_by_bytes < 0)
        is->seek_by_bytes = !!(is->ic->iformat->flags & AVFMT_TS_DISCONT) && strcmp("ogg", is->ic->iformat->name);
	
    is->max_frame_duration = (is->ic->iformat->flags & AVFMT_TS_DISCONT) ? 10.0 : 3600.0;
    
    //
    
    is->realtime = is_realtime(is->ic);
    
	for (int i = 0; i < is->ic->nb_streams; i++)
		is->ic->streams[i]->discard = AVDISCARD_ALL;
    
    // LAVP: av_find_best_stream is moved to read_thread()
    
	// dump format info
	if (is->show_status) {
		av_dump_format(is->ic, 0, is->filename, 0);
	}
    
    /* ======================================== */
	
    /* original: stream_open() */
    {
        is->pictq_mutex = LAVPCreateMutex();
        is->pictq_cond = LAVPCreateCond();

        is->subpq_mutex = LAVPCreateMutex();
        is->subpq_cond = LAVPCreateCond();

        packet_queue_init(&is->audioq);
        packet_queue_init(&is->videoq);
        packet_queue_init(&is->subtitleq);

        is->continue_read_thread = LAVPCreateCond();

        //
        init_clock(&is->vidclk, &is->videoq.serial);
        init_clock(&is->audclk, &is->audioq.serial);
        init_clock(&is->extclk, &is->extclk.serial);

        is->audio_clock_serial = -1;
        is->audio_last_serial = -1;
        is->av_sync_type = AV_SYNC_AUDIO_MASTER; // LAVP: fixed value

        // LAVP: Using dispatch queue
        {
            dispatch_queue_t parse_queue = dispatch_queue_create("parse", NULL);
            dispatch_group_t parse_group = dispatch_group_create();
            is->parse_queue = (__bridge_retained void*)parse_queue;
            is->parse_group = (__bridge_retained void*)parse_group;
        }
        dispatch_group_async((__bridge dispatch_group_t)is->parse_group, (__bridge dispatch_queue_t)is->parse_queue, ^(void){read_thread(is);});
    }
	return is;
	
bail:
    av_log(NULL, AV_LOG_ERROR, "ret = %d, err = %d\n", ret, err);
	if (is->filename)
        free(is->filename);
    free (is);
	return NULL;
}

/*
 TODO:
 stream_cycle_channel()
 toggle_audio_display()
 opt_show_mode()
 */

double_t stream_playRate(VideoState *is)
{
	return is->playRate;
}

void stream_setPlayRate(VideoState *is, double_t newRate)
{
	assert(newRate > 0.0);
	
	is->playRate = newRate;
    
    set_clock_speed(&is->vidclk, newRate);
    set_clock_speed(&is->audclk, newRate);
    set_clock_speed(&is->extclk, newRate);
}
