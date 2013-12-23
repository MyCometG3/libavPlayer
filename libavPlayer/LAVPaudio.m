/*
 *  LAVPaudio.c
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

static void update_sample_display(VideoState *is, short *samples, int samples_size);
static int synchronize_audio(VideoState *is, int nb_samples);
int audio_decode_frame(VideoState *is);

BOOL audio_isPitchChanged(VideoState *is);
void audio_updatePitch(VideoState *is);

/* =========================================================== */

#pragma mark -

int audio_open(void *opaque, int64_t wanted_channel_layout, int wanted_nb_channels, int wanted_sample_rate, struct AudioParams *audio_hw_params)
{
    /* LAVP: TODO Simple 48KHz stereo output by default */
    if (wanted_sample_rate <= 0) {
        wanted_sample_rate = 48000;
    }
    
    if (wanted_nb_channels <= 0) {
        wanted_nb_channels = 2;
    }
    
    if (!wanted_channel_layout || wanted_nb_channels != av_get_channel_layout_nb_channels(wanted_channel_layout)) {
        wanted_channel_layout = av_get_default_channel_layout(wanted_nb_channels);
        wanted_channel_layout &= ~AV_CH_LAYOUT_STEREO_DOWNMIX;
    }
    
    audio_hw_params->fmt = AV_SAMPLE_FMT_S16;
    audio_hw_params->freq = wanted_sample_rate;
    audio_hw_params->channel_layout = wanted_channel_layout;
    audio_hw_params->channels =  wanted_nb_channels;
    return SDL_AUDIO_BUFFER_SIZE * audio_hw_params->channels * av_get_bytes_per_sample(audio_hw_params->fmt);
}

/* copy samples for viewing in editor window */
static void update_sample_display(VideoState *is, short *samples, int samples_size)
{
    int size, len;
    
    size = samples_size / sizeof(short);
    while (size > 0) {
        len = SAMPLE_ARRAY_SIZE - is->sample_array_index;
        if (len > size)
            len = size;
        memcpy(is->sample_array + is->sample_array_index, samples, len * sizeof(short));
        samples += len;
        is->sample_array_index += len;
        if (is->sample_array_index >= SAMPLE_ARRAY_SIZE)
            is->sample_array_index = 0;
        size -= len;
    }
}

/* return the wanted number of samples to get better sync if sync_type is video
 * or external master clock */
static int synchronize_audio(VideoState *is, int nb_samples)
{
    int wanted_nb_samples = nb_samples;
    
    /* if not master, then we try to remove or add samples to correct the clock */
    if (get_master_sync_type(is) != AV_SYNC_AUDIO_MASTER) {
        double diff, avg_diff;
        int min_nb_samples, max_nb_samples;
        
        diff = get_clock(&is->audclk) - get_master_clock(is);
        
        if (!isnan(diff) && fabs(diff) < AV_NOSYNC_THRESHOLD) {
            is->audio_diff_cum = diff + is->audio_diff_avg_coef * is->audio_diff_cum;
            if (is->audio_diff_avg_count < AUDIO_DIFF_AVG_NB) {
                /* not enough measures to have a correct estimate */
                is->audio_diff_avg_count++;
            } else {
                /* estimate the A-V difference */
                avg_diff = is->audio_diff_cum * (1.0 - is->audio_diff_avg_coef);
                
                if (fabs(avg_diff) >= is->audio_diff_threshold) {
                    wanted_nb_samples = nb_samples + (int)(diff * is->audio_src.freq);
                    min_nb_samples = ((nb_samples * (100 - SAMPLE_CORRECTION_PERCENT_MAX) / 100));
                    max_nb_samples = ((nb_samples * (100 + SAMPLE_CORRECTION_PERCENT_MAX) / 100));
                    wanted_nb_samples = FFMIN(FFMAX(wanted_nb_samples, min_nb_samples), max_nb_samples);
                }
                av_dlog(NULL, "diff=%f adiff=%f sample_diff=%d apts=%0.3f %f\n",
                        diff, avg_diff, wanted_nb_samples - nb_samples,
                        is->audio_clock, is->audio_diff_threshold);
            }
        } else {
            /* too big difference : may be initial PTS errors, so
             reset A-V filter */
            is->audio_diff_avg_count = 0;
            is->audio_diff_cum       = 0;
        }
    }
    
    return wanted_nb_samples;
}

/**
 * Decode one audio frame and return its uncompressed size.
 *
 * The processed audio frame is decoded, converted if required, and
 * stored in is->audio_buf, with size in bytes given by the return
 * value.
 */
int audio_decode_frame(VideoState *is)
{
    AVPacket *pkt_temp = &is->audio_pkt_temp;
    AVPacket *pkt = &is->audio_pkt;
    AVCodecContext *dec = is->audio_st->codec;
    int len1, data_size, resampled_data_size;
    int64_t dec_channel_layout;
    int got_frame;
    av_unused double audio_clock0;
    int wanted_nb_samples;
    AVRational tb = { 0 }; /* LAVP: should be initialized */
    // LAVP:
    
    for(;;) {
        /* NOTE: the audio packet can contain several frames */
        while (pkt_temp->stream_index != -1 || is->audio_buf_frames_pending) {
            if (!is->frame) {
                if (!(is->frame = av_frame_alloc()))
                    return AVERROR(ENOMEM);
            } else {
                av_frame_unref(is->frame);
            }
            
            if (is->audioq.serial != is->audio_pkt_temp_serial)
                break;
            
            if (is->paused)
                return -1;
            
            if (!is->audio_buf_frames_pending) {
                len1 = avcodec_decode_audio4(dec, is->frame, &got_frame, pkt_temp);
                if (len1 < 0) {
                    /* if error, we skip the frame */
                    pkt_temp->size = 0;
                    break;
                }
                
                pkt_temp->dts =
                pkt_temp->pts = AV_NOPTS_VALUE;
                pkt_temp->data += len1;
                pkt_temp->size -= len1;
                if ((pkt_temp->data && pkt_temp->size <= 0) || (!pkt_temp->data && !got_frame))
                    pkt_temp->stream_index = -1;
                if (!pkt_temp->data && !got_frame)
                    is->audio_finished = is->audio_pkt_temp_serial;
                
                if (!got_frame)
                    continue;
                
                tb = (AVRational){1, is->frame->sample_rate};
                if (is->frame->pts != AV_NOPTS_VALUE)
                    is->frame->pts = av_rescale_q(is->frame->pts, dec->time_base, tb);
                else if (is->frame->pkt_pts != AV_NOPTS_VALUE)
                    is->frame->pts = av_rescale_q(is->frame->pkt_pts, is->audio_st->time_base, tb);
                else if (is->audio_frame_next_pts != AV_NOPTS_VALUE)
#if 0
                    // LAVP:
#else
                    is->frame->pts = av_rescale_q(is->audio_frame_next_pts, (AVRational){1, is->audio_src.freq}, tb);
#endif
                if (is->frame->pts != AV_NOPTS_VALUE)
                    is->audio_frame_next_pts = is->frame->pts + is->frame->nb_samples;
                
#if 0
                // LAVP:
#endif
            }
#if 0
            // LAVP:
#endif
            
            data_size = av_samples_get_buffer_size(NULL, av_frame_get_channels(is->frame),
                                                   is->frame->nb_samples,
                                                   is->frame->format, 1);
            
            dec_channel_layout =
                (is->frame->channel_layout && av_frame_get_channels(is->frame) == av_get_channel_layout_nb_channels(is->frame->channel_layout)) ?
                is->frame->channel_layout : av_get_default_channel_layout(av_frame_get_channels(is->frame));
            wanted_nb_samples = synchronize_audio(is, is->frame->nb_samples);
            
            if (is->frame->format        != is->audio_src.fmt            ||
                dec_channel_layout       != is->audio_src.channel_layout ||
                is->frame->sample_rate   != is->audio_src.freq           ||
                (wanted_nb_samples       != is->frame->nb_samples && !is->swr_ctx)) {
                swr_free(&is->swr_ctx);
                is->swr_ctx = swr_alloc_set_opts(NULL,
                                                 is->audio_tgt.channel_layout, is->audio_tgt.fmt, is->audio_tgt.freq,
                                                 dec_channel_layout,           is->frame->format, is->frame->sample_rate,
                                                 0, NULL);
                if (!is->swr_ctx || swr_init(is->swr_ctx) < 0) {
                    av_log(NULL, AV_LOG_ERROR,
                           "Cannot create sample rate converter for conversion of %d Hz %s %d channels to %d Hz %s %d channels!\n",
                           is->frame->sample_rate, av_get_sample_fmt_name(is->frame->format), av_frame_get_channels(is->frame),
                           is->audio_tgt.freq, av_get_sample_fmt_name(is->audio_tgt.fmt), is->audio_tgt.channels);
                    break;
                }
                is->audio_src.channel_layout = dec_channel_layout;
                is->audio_src.channels       = av_frame_get_channels(is->frame);
                is->audio_src.freq = is->frame->sample_rate;
                is->audio_src.fmt = is->frame->format;
            }
            
            if (is->swr_ctx) {
                const uint8_t **in = (const uint8_t **)is->frame->extended_data;
                uint8_t **out = &is->audio_buf1;
                int out_count = (int64_t)wanted_nb_samples * is->audio_tgt.freq / is->frame->sample_rate + 256;
                int out_size  = av_samples_get_buffer_size(NULL, is->audio_tgt.channels, out_count, is->audio_tgt.fmt, 0);
                int len2;
                if (out_size < 0) {
                    av_log(NULL, AV_LOG_ERROR, "av_samples_get_buffer_size() failed\n");
                    break;
                }
                if (wanted_nb_samples != is->frame->nb_samples) {
                    if (swr_set_compensation(is->swr_ctx, (wanted_nb_samples - is->frame->nb_samples) * is->audio_tgt.freq / is->frame->sample_rate,
                                             wanted_nb_samples * is->audio_tgt.freq / is->frame->sample_rate) < 0) {
                        av_log(NULL, AV_LOG_ERROR, "swr_set_compensation() failed\n");
                        break;
                    }
                }
                av_fast_malloc(&is->audio_buf1, &is->audio_buf1_size, out_size);
                if (!is->audio_buf1)
                    return AVERROR(ENOMEM);
                len2 = swr_convert(is->swr_ctx, out, out_count, in, is->frame->nb_samples);
                if (len2 < 0) {
                    av_log(NULL, AV_LOG_ERROR, "swr_convert() failed\n");
                    break;
                }
                if (len2 == out_count) {
                    av_log(NULL, AV_LOG_WARNING, "audio buffer is probably too small\n");
                    swr_init(is->swr_ctx);
                }
                is->audio_buf = is->audio_buf1;
                resampled_data_size = len2 * is->audio_tgt.channels * av_get_bytes_per_sample(is->audio_tgt.fmt);
            } else {
                is->audio_buf = is->frame->data[0];
                resampled_data_size = data_size;
            }
            
            audio_clock0 = is->audio_clock;
            /* update the audio clock with the pts */
            if (is->frame->pts != AV_NOPTS_VALUE)
                is->audio_clock = is->frame->pts * av_q2d(tb) + (double) is->frame->nb_samples / is->frame->sample_rate;
            else
                is->audio_clock = NAN;
            is->audio_clock_serial = is->audio_pkt_temp_serial;
#ifdef DEBUG
            {
                static double last_clock;
                printf("audio: delay=%0.3f clock=%0.3f clock0=%0.3f\n",
                       is->audio_clock - last_clock,
                       is->audio_clock, audio_clock0);
                last_clock = is->audio_clock;
            }
#endif
            return resampled_data_size;
        }
        
        /* free the current packet */
        if (pkt->data)
            av_free_packet(pkt);
        memset(pkt_temp, 0, sizeof(*pkt_temp));
        pkt_temp->stream_index = -1;
        
        if (is->audioq.abort_request) {
            return -1;
        }
        
        if (is->audioq.nb_packets == 0)
            LAVPCondSignal(is->continue_read_thread);
        
        /* read next packet */
        if ((packet_queue_get(&is->audioq, pkt, 1, &is->audio_pkt_temp_serial)) < 0)
            return -1;
        
        if (pkt->data == is->audioq.flush_pkt.data) {
            avcodec_flush_buffers(dec);
            is->audio_buf_frames_pending = 0;
            is->audio_frame_next_pts = AV_NOPTS_VALUE;
            if ((is->ic->iformat->flags & (AVFMT_NOBINSEARCH | AVFMT_NOGENSEARCH | AVFMT_NO_BYTE_SEEK)) && !is->ic->iformat->read_seek)
                is->audio_frame_next_pts = is->audio_st->start_time;
        }
        
        *pkt_temp = *pkt;
    }
}

/* prepare a new audio buffer */
/* LAVP: original: sdl_audio_callback() */
static void inCallbackProc (void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer)
{
    @autoreleasepool {
        //NSLog(@"DEBUG: inCallbackProc");
        
        uint8_t *stream = inBuffer->mAudioData;
        int len = inBuffer->mAudioDataBytesCapacity;
        
        //
        VideoState *is = inUserData;
        int audio_size, len1;
        int bytes_per_sec;
        int frame_size = av_samples_get_buffer_size(NULL, is->audio_tgt.channels, 1, is->audio_tgt.fmt, 1);
        
        is->audio_callback_time = av_gettime();
        
        while (len > 0) {
            if (is->audio_buf_index >= is->audio_buf_size) {
                audio_size = audio_decode_frame(is);
                if (audio_size < 0) {
                    /* if error, just output silence */
                    is->audio_buf      = is->silence_buf;
                    is->audio_buf_size = sizeof(is->silence_buf) / frame_size * frame_size;
                } else {
                    if (is->show_mode != SHOW_MODE_VIDEO)
                        update_sample_display(is, (int16_t *)is->audio_buf, audio_size);
                    is->audio_buf_size = audio_size;
                }
                is->audio_buf_index = 0;
            }
            len1 = is->audio_buf_size - is->audio_buf_index;
            if (len1 > len)
                len1 = len;
            memcpy(stream, (uint8_t *)is->audio_buf + is->audio_buf_index, len1);
            len -= len1;
            stream += len1;
            is->audio_buf_index += len1;
        }
        bytes_per_sec = is->audio_tgt.freq * is->audio_tgt.channels * av_get_bytes_per_sample(is->audio_tgt.fmt);
        is->audio_write_buf_size = is->audio_buf_size - is->audio_buf_index;
        
        /* Let's assume the audio driver that is used by SDL has two periods. */
        if (!isnan(is->audio_clock)) {
            set_clock_at(&is->audclk, is->audio_clock - (double)(2 * is->audio_hw_buf_size + is->audio_write_buf_size) / bytes_per_sec, is->audio_clock_serial, is->audio_callback_time / 1000000.0);
            sync_clock_to_slave(&is->extclk, &is->audclk);
        }
        
        /* LAVP: Enqueue LPCM result into Audio Queue */
        inBuffer->mAudioDataByteSize = stream - (UInt8 *)inBuffer->mAudioData;
        OSStatus err = AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
        if (err) {
            NSString *errStr = @"kAudioQueueErr_???";
            switch (err) {
                case kAudioQueueErr_DisposalPending:
                    errStr = @"kAudioQueueErr_DisposalPending"; break;
                case kAudioQueueErr_InvalidDevice:
                    errStr = @"kAudioQueueErr_InvalidDevice"; break;
                case kAudioQueueErr_InvalidRunState:
                    errStr = @"kAudioQueueErr_InvalidRunState"; break;
                case kAudioQueueErr_QueueInvalidated:
                    errStr = @"kAudioQueueErr_QueueInvalidated"; break;
                case kAudioQueueErr_EnqueueDuringReset:
                    errStr = @"kAudioQueueErr_EnqueueDuringReset"; break;
            }
            NSLog(@"DEBUG: AudioQueueEnqueueBuffer() returned %d (%@)", err, errStr);
        }
    }
}

#pragma mark -

static void LAVPFillASBD(VideoState *is, AVCodecContext *avctx)
{
	Float64 inSampleRate = avctx->sample_rate;
	UInt32 inTotalBitsPerChannels = 16, inValidBitsPerChannel = 16;	// Packed
	UInt32 inChannelsPerFrame = avctx->channels;
	UInt32 inFramesPerPacket = 1;
	UInt32 inBytesPerFrame = inChannelsPerFrame * inTotalBitsPerChannels/8;
	UInt32 inBytesPerPacket = inBytesPerFrame * inFramesPerPacket;
	
	memset(&is->asbd, 0, sizeof(AudioStreamBasicDescription));
	is->asbd.mSampleRate = inSampleRate;
	is->asbd.mFormatID = kAudioFormatLinearPCM;
	is->asbd.mFormatFlags = kAudioFormatFlagIsSignedInteger | kAudioFormatFlagIsPacked;
	//is->asbd.mFormatFlags |= kAudioFormatFlagIsBigEndian;
	is->asbd.mBytesPerPacket = inBytesPerPacket;
	is->asbd.mFramesPerPacket = inFramesPerPacket;
	is->asbd.mBytesPerFrame = inBytesPerFrame;
	is->asbd.mChannelsPerFrame = inChannelsPerFrame;
	is->asbd.mBitsPerChannel = inValidBitsPerChannel;
}

/* LAVP: original: audio_open() */
void LAVPAudioQueueInit(VideoState *is, AVCodecContext *avctx)
{
    if (is->outAQ) return;
    
	//NSLog(@"DEBUG: LAVPAudioQueueInit");
	
	if (!avctx->sample_rate) {
		// NOTE: is->outAQ, is->audioDispatchQueue are left uninitialized
		
		// Audio clock is not available
		if (is->av_sync_type == AV_SYNC_AUDIO_MASTER) 
			is->av_sync_type = AV_SYNC_VIDEO_MASTER;
		
		return;
	}

    // prepare Audio stream basic description
    LAVPFillASBD(is, avctx);
    
    // prepare AudioQueue for Output
    OSStatus err = 0;
    AudioQueueRef outAQ = NULL;
#if 1
    if (!is->audioDispatchQueue) {
        // using dispatch queue and block object
        void (^inCallbackBlock)() = ^(AudioQueueRef inAQ, AudioQueueBufferRef inBuffer)
        {
            /* AudioQueue Callback should be ignored when closing */
            if (is->abort_request) return;
            
            inCallbackProc(is, inAQ, inBuffer);
        };
        
        dispatch_queue_t audioDispatchQueue = dispatch_queue_create("audio", DISPATCH_QUEUE_SERIAL);
        is->audioDispatchQueue = (__bridge_retained void*)audioDispatchQueue;
        err = AudioQueueNewOutputWithDispatchQueue(&outAQ, &is->asbd, 0, (__bridge dispatch_queue_t)is->audioDispatchQueue, inCallbackBlock);
    }
#else
    // using direct callback
    err = AudioQueueNewOutput(&is->asbd, inCallbackProc, is, 0, 0, 0, &outAQ);
#endif
    assert(err == 0 && outAQ != NULL);
    is->outAQ = outAQ;
    
    // Enable timepitch
    UInt32 propValue = 1;
    err = AudioQueueSetProperty (is->outAQ, kAudioQueueProperty_EnableTimePitch, &propValue, sizeof(propValue));
    assert(err == 0);
    
    // Preserve original pitch (using FFT filter)
    propValue = kAudioQueueTimePitchAlgorithm_Spectral;
    err = AudioQueueSetProperty (is->outAQ, kAudioQueueProperty_TimePitchAlgorithm, &propValue, sizeof(propValue));
    assert(err == 0);
    
    // prepare audio queue buffers for Output
    UInt32 inBufferByteSize = (is->asbd.mSampleRate / 50) * is->asbd.mBytesPerFrame;	// perform callback 50 times per sec
    for( int i = 0; i < 3; i++ ) {
        // Allocate Buffer
        AudioQueueBufferRef outBuffer = NULL;
        err = AudioQueueAllocateBuffer(is->outAQ, inBufferByteSize, &outBuffer);
        assert(err == 0 && outBuffer != NULL);
        
        // Nullify data
        memset(outBuffer->mAudioData, 0, outBuffer->mAudioDataBytesCapacity);
        
        // Enqueue dummy data to start queuing
        outBuffer->mAudioDataByteSize=8; // dummy data
        AudioQueueEnqueueBuffer(is->outAQ, outBuffer, 0, 0);
    }
}	

void LAVPAudioQueueStart(VideoState *is)
{
	if (!is->outAQ) return;
	
	//NSLog(@"DEBUG: LAVPAudioQueueStart");
	
	// Update playback rate
	BOOL pitchDiff = audio_isPitchChanged(is);
	if ( pitchDiff ) {
		// NOTE: kAudioQueueParam_PlayRate and kAudioQueueProperty_TimePitchBypass
        // can be modified without LAVPAudioQueueStop(is);
		audio_updatePitch(is);
	}
	pitchDiff = audio_isPitchChanged(is);
	if ( pitchDiff ) {
		NSLog(@"ERROR: Failed to update pitch.");
		assert(!pitchDiff);
	}
	
	//
	OSStatus err = 0;
	UInt32 inNumberOfFramesToPrepare = is->asbd.mSampleRate / 60;	// Prepare for 1/60 sec
    
	err = AudioQueuePrime(is->outAQ, inNumberOfFramesToPrepare, 0);
	assert(err == 0);
	
	err = AudioQueueStart(is->outAQ, NULL);
	assert(err == 0);
}

void LAVPAudioQueuePause(VideoState *is)
{
	if (!is->outAQ) return;
	
	//NSLog(@"DEBUG: LAVPAudioQueuePause");
	
    //
	OSStatus err = 0;
	
    err = AudioQueueFlush(is->outAQ);
	assert(err == 0);
	
	err = AudioQueuePause(is->outAQ);
	assert(err == 0);
}

void LAVPAudioQueueStop(VideoState *is)
{
	if (!is->outAQ) return;
	
	//NSLog(@"DEBUG: LAVPAudioQueueStop");
	
	// Check AudioQueue is running or not
	OSStatus err = 0;
	UInt32 currentRunning = 0;
	UInt32 currentRunningSize = sizeof(currentRunning);
    
	err = AudioQueueGetProperty(is->outAQ, kAudioQueueProperty_IsRunning, &currentRunning, &currentRunningSize);
	assert(err == 0);
	
	// Stop AudioQueue
	if (currentRunning) {
#if 1
		// Specifying YES with AudioQueueStop() to wait untill done
		err = AudioQueueStop(is->outAQ, YES);
		assert(err == 0);
#else
		// Specifying NO with AudioQueueStop() to avoid severe threading issue
		err = AudioQueueStop(is->outAQ, NO);
		assert(err == 0);
		
		// wait - blocking
		int retry = 100;	// 1.0 sec max
		while (retry--) {
			currentRunning = 0;
			currentRunningSize = sizeof(currentRunning);
			
			usleep(10*1000);
            
			err = AudioQueueGetProperty(is->outAQ, kAudioQueueProperty_IsRunning, &currentRunning, &currentRunningSize);
			if (err == 0 && currentRunning == 0) break;
		}
		if (retry < 0) {
			NSLog(@"ERROR: Failed to stop AudioQueue.");
			assert(retry>=0);
		}
#endif
	}
    
	//NSLog(@"DEBUG: LAVPAudioQueueStop done");
}

void LAVPAudioQueueDealloc(VideoState *is)
{
	if (!is->outAQ) return;
	
	//NSLog(@"DEBUG: LAVPAudioQueueDealloc");
	
    // stop AudioQueue
	OSStatus err = 0;
    
    err = AudioQueueReset(is->outAQ);
    assert(err == 0);
	
    err = AudioQueueDispose(is->outAQ, NO);
	assert(err == 0);
	
	is->outAQ = NULL;
	
    // stop dispatch queue
    if (is->audioDispatchQueue) {
        dispatch_queue_t audioDispatchQueue = (__bridge_transfer dispatch_queue_t)is->audioDispatchQueue;
        audioDispatchQueue = NULL; // ARC
        is->audioDispatchQueue = NULL;
    }
    
	//NSLog(@"DEBUG: LAVPAudioQueueDealloc done");
}

AudioQueueParameterValue getVolume(VideoState *is)
{
	if (!is->outAQ) return 0.0;
	
	OSStatus err = 0;
	AudioQueueParameterValue volume;
    
    err = AudioQueueGetParameter(is->outAQ, kAudioQueueParam_Volume, &volume);
	assert(!err);
    
	return volume;
}

void setVolume(VideoState *is, AudioQueueParameterValue volume)
{
	if (!is->outAQ) return;
	
	OSStatus err = 0;
    
    err = AudioQueueSetParameter(is->outAQ, kAudioQueueParam_Volume, volume);
	assert(!err);
}

BOOL audio_isPitchChanged(VideoState *is)
{
	if (!is->outAQ) return NO;
	
	OSStatus err = 0;
	
	// Compare current playrate b/w AudioQueue and VideoState
	Float32 currentRate = 0;
	err = AudioQueueGetParameter(is->outAQ, kAudioQueueParam_PlayRate, &currentRate);	// acceleration
	assert(err == 0);
	
	if (currentRate == is->playRate) {
		return NO;
	} else {
		return YES;
	}
}

void audio_updatePitch(VideoState *is)
{
	if (!is->outAQ) return;
	
	OSStatus err = 0;
	
	assert(is->playRate > 0.0);
	
    //NSLog(@"DEBUG: is->playRate = %.1f", is->playRate);
    
	if (is->playRate == 1.0) {
		// Set playrate
		err = AudioQueueSetParameter(is->outAQ, kAudioQueueParam_PlayRate, is->playRate);
		assert(err == 0);
		
		// Bypass TimePitch
		UInt32 propValue = 1;
		err = AudioQueueSetProperty (is->outAQ, kAudioQueueProperty_TimePitchBypass, &propValue, sizeof(propValue));
		assert(err == 0);
	} else {
		// Set playrate
		err = AudioQueueSetParameter(is->outAQ, kAudioQueueParam_PlayRate, is->playRate);
		assert(err == 0);
		
		// Use TimePitch (using FFT filter)
		UInt32 propValue = 0;
		err = AudioQueueSetProperty (is->outAQ, kAudioQueueProperty_TimePitchBypass, &propValue, sizeof(propValue));
		assert(err == 0);
	}
}
