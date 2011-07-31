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

/* maximum audio speed change to get correct sync */
#define SAMPLE_CORRECTION_PERCENT_MAX 10

/* =========================================================== */

int audio_write_get_buf_size(VideoState *is);

int synchronize_audio(VideoState *is, short *samples,
					  int samples_size1, double pts);
int audio_decode_frame(VideoState *is, double *pts_ptr);

/* =========================================================== */

#pragma mark -

/* get the current audio output buffer size, in samples. We
 cannot have a precise information */
int audio_write_get_buf_size(VideoState *is)
{
    return is->audio_buf_size - is->audio_buf_index;
}

/* get the current audio clock value */
double get_audio_clock(VideoState *is)
{
    double pts;
    int hw_buf_size, bytes_per_sec;
    pts = is->audio_clock;
    hw_buf_size = audio_write_get_buf_size(is);
    bytes_per_sec = 0;
    if (is->audio_st) {
        bytes_per_sec = is->audio_st->codec->sample_rate *
		2 * is->audio_st->codec->channels;
    }
    if (bytes_per_sec)
        pts -= (double)hw_buf_size / bytes_per_sec;
    return pts;
}

/* return the new audio buffer size (samples can be added or deleted
 to get better sync if video or external master clock) */
int synchronize_audio(VideoState *is, short *samples,
					  int samples_size1, double pts)
{
    int n, samples_size;
    double ref_clock;
	
    n = 2 * is->audio_st->codec->channels;
    samples_size = samples_size1;
	
    /* if not master, then we try to remove or add samples to correct the clock */
    if (((is->av_sync_type == AV_SYNC_VIDEO_MASTER && is->video_st) ||
         is->av_sync_type == AV_SYNC_EXTERNAL_CLOCK)) {
        double diff, avg_diff;
        int wanted_size, min_size, max_size, nb_samples;
		
        ref_clock = get_master_clock(is);
        diff = get_audio_clock(is) - ref_clock;
		
        if (diff < AV_NOSYNC_THRESHOLD) {
            is->audio_diff_cum = diff + is->audio_diff_avg_coef * is->audio_diff_cum;
            if (is->audio_diff_avg_count < AUDIO_DIFF_AVG_NB) {
                /* not enough measures to have a correct estimate */
                is->audio_diff_avg_count++;
            } else {
                /* estimate the A-V difference */
                avg_diff = is->audio_diff_cum * (1.0 - is->audio_diff_avg_coef);
				
                if (fabs(avg_diff) >= is->audio_diff_threshold) {
                    wanted_size = samples_size + ((int)(diff * is->audio_st->codec->sample_rate) * n);
                    nb_samples = samples_size / n;
					
                    min_size = ((nb_samples * (100 - SAMPLE_CORRECTION_PERCENT_MAX)) / 100) * n;
                    max_size = ((nb_samples * (100 + SAMPLE_CORRECTION_PERCENT_MAX)) / 100) * n;
                    if (wanted_size < min_size)
                        wanted_size = min_size;
                    else if (wanted_size > max_size)
                        wanted_size = max_size;
					
                    /* add or remove samples to correction the synchro */
                    if (wanted_size < samples_size) {
                        /* remove samples */
                        samples_size = wanted_size;
                    } else if (wanted_size > samples_size) {
                        uint8_t *samples_end, *q;
                        int nb;
						
                        /* add samples */
                        nb = (samples_size - wanted_size);
                        samples_end = (uint8_t *)samples + samples_size - n;
                        q = samples_end + n;
                        while (nb > 0) {
                            memcpy(q, samples_end, n);
                            q += n;
                            nb -= n;
                        }
                        samples_size = wanted_size;
                    }
                }
                av_dlog(NULL, "diff=%f adiff=%f sample_diff=%d apts=%0.3f vpts=%0.3f %f\n",
                        diff, avg_diff, samples_size - samples_size1,
                        is->audio_clock, is->video_clock, is->audio_diff_threshold);
            }
        } else {
            /* too big difference : may be initial PTS errors, so
			 reset A-V filter */
            is->audio_diff_avg_count = 0;
            is->audio_diff_cum = 0;
        }
    }
	
    return samples_size;
}

/* decode one audio frame and returns its uncompressed size */
int audio_decode_frame(VideoState *is, double *pts_ptr)
{
    if (!is->audio_st) return -1;
    if (!is->audio_st->codec) return -1;
	
	AVPacket *pkt_temp = &is->audio_pkt_temp;
    AVPacket *pkt = &is->audio_pkt;
    AVCodecContext *dec= is->audio_st->codec;
    int n, len1, data_size;
    double pts;
	
    for(;;) {
        /* NOTE: the audio packet can contain several frames */
        while (pkt_temp->size > 0) {
            data_size = sizeof(is->audio_buf1);
            len1 = avcodec_decode_audio3(dec,
										 (int16_t *)is->audio_buf1, &data_size,
										 pkt_temp);
            if (len1 < 0) {
                /* if error, we skip the frame */
                pkt_temp->size = 0;
                break;
            }
			
            pkt_temp->data += len1;
            pkt_temp->size -= len1;
            if (data_size <= 0)
                continue;
			
            if (dec->sample_fmt != is->audio_src_fmt) {
                if (is->reformat_ctx)
                    av_audio_convert_free(is->reformat_ctx);
                is->reformat_ctx= av_audio_convert_alloc(AV_SAMPLE_FMT_S16, 1,
                                                         dec->sample_fmt, 1, NULL, 0);
                if (!is->reformat_ctx) {
                    fprintf(stderr, "Cannot convert %s sample format to %s sample format\n",
							av_get_sample_fmt_name(dec->sample_fmt),
							av_get_sample_fmt_name(AV_SAMPLE_FMT_S16));
					break;
                }
                is->audio_src_fmt= dec->sample_fmt;
            }
			
            if (is->reformat_ctx) {
                const void *ibuf[6]= {is->audio_buf1};
                void *obuf[6]= {is->audio_buf2};
                int istride[6]= {av_get_bytes_per_sample(dec->sample_fmt)};
                int ostride[6]= {2};
                int len= data_size/istride[0];
                if (av_audio_convert(is->reformat_ctx, obuf, ostride, ibuf, istride, len)<0) {
                    printf("av_audio_convert() failed\n");
                    break;
                }
                is->audio_buf= is->audio_buf2;
                /* FIXME: existing code assume that data_size equals framesize*channels*2
				 remove this legacy cruft */
                data_size= len*2;
            }else{
                is->audio_buf= is->audio_buf1;
            }
			
            /* if no pts, then compute it */
            pts = is->audio_clock;
            *pts_ptr = pts;
            n = 2 * dec->channels;
            is->audio_clock += (double)data_size /
			(double)(n * dec->sample_rate);
#ifdef DEBUG
            {
                static double last_clock;
                printf("audio: delay=%0.3f clock=%0.3f pts=%0.3f\n",
                       is->audio_clock - last_clock,
                       is->audio_clock, pts);
                last_clock = is->audio_clock;
            }
#endif
            return data_size;
        }
		
        /* free the current packet */
        if (pkt->data)
            av_free_packet(pkt);
		
        if (is->paused || is->audioq.abort_request) {
            return -1;
        }
		
        /* read next packet */
        if (packet_queue_get(&is->audioq, pkt, 1) < 0)
            return -1;
        if(pkt->data == is->audioq.flush_pkt.data){
            avcodec_flush_buffers(dec);
            continue;
        }
		
        pkt_temp->data = pkt->data;
        pkt_temp->size = pkt->size;
		
        /* if update the audio clock with the pts */
        if (pkt->pts != AV_NOPTS_VALUE) {
            is->audio_clock = av_q2d(is->audio_st->time_base)*pkt->pts;
        }
    }
}

static void inCallbackProc (void *inUserData, AudioQueueRef inAQ, AudioQueueBufferRef inBuffer)
{
	//NSLog(@"inCallbackProc");
	
	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	
	uint8_t *stream = inBuffer->mAudioData;
	int len = inBuffer->mAudioDataBytesCapacity;
	
	//
	VideoState *is = inUserData;
	int audio_size, len1;
	double pts;
	
	is->audio_callback_time = av_gettime();
	
	while (len > 0) {
		if (is->audio_buf_index >= is->audio_buf_size) {
			audio_size = audio_decode_frame(is, &pts);
			if (audio_size < 0) {
				/* if error, just output silence */
				is->audio_buf = is->audio_buf1;
				is->audio_buf_size = 1024;
				memset(is->audio_buf, 0, is->audio_buf_size);
			} else {
				audio_size = synchronize_audio(is, (int16_t *)is->audio_buf, audio_size, pts);
				is->audio_buf_size = audio_size;
			}
			is->audio_buf_index = 0;
			//NSLog(@"audio_size = %d; audio_buf_size = %d", audio_size, is->audio_buf_size);
		}
		len1 = is->audio_buf_size - is->audio_buf_index;
		if (len1 > len)
			len1 = len;
		memcpy(stream, (uint8_t *)is->audio_buf + is->audio_buf_index, len1);
		len -= len1;
		stream += len1;
		is->audio_buf_index += len1;
	}
	
	//
	inBuffer->mAudioDataByteSize = stream - (UInt8 *)inBuffer->mAudioData;
	OSStatus err = AudioQueueEnqueueBuffer(inAQ, inBuffer, 0, NULL);
	assert(err == 0);
	
	[pool drain];
}

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

void LAVPAudioQueueInit(VideoState *is, AVCodecContext *avctx)
{
	//NSLog(@"LAVPAudioQueueInit");
	
	if (!is->outAQ) {
		//
		LAVPFillASBD(is, avctx);
		
		//
		OSStatus err = 0;
		AudioQueueRef outAQ = NULL;
		is->audioDispatchQueue = dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0);
#if 1
		void (^inCallbackBlock)(AudioQueueRef, AudioQueueBufferRef) = ^(AudioQueueRef inAQ, AudioQueueBufferRef inBuffer) 
		{
			inCallbackProc(is, inAQ, inBuffer);
		};
		err = AudioQueueNewOutputWithDispatchQueue(&outAQ, &is->asbd, 0, is->audioDispatchQueue, inCallbackBlock);
#else
		err = AudioQueueNewOutput(&is->asbd, inCallbackProc, is, 
								  0, 0, 
								  0, &outAQ);
#endif
		is->outAQ = outAQ;
		assert(err == 0 && outAQ != NULL);
		
		//
		UInt32 inBufferByteSize = is->asbd.mSampleRate * is->asbd.mBytesPerFrame / 60;	// perform callback 60 times per sec
		for( int i = 0; i < 3; i++ ) {
			AudioQueueBufferRef outBuffer = NULL;
			err = AudioQueueAllocateBuffer(is->outAQ, inBufferByteSize, &outBuffer);
			assert(err == 0 && outBuffer != NULL);
			
			inCallbackProc(is, is->outAQ, outBuffer);	// AudioQueuePrime does instead
		}
	}
}	

void LAVPAudioQueueStart(VideoState *is)
{
	//NSLog(@"LAVPAudioQueueStart");
	
	OSStatus err = 0;
	UInt32 inNumberOfFramesToPrepare = is->asbd.mSampleRate/5;	// Prepare for 0.2 sec
	err = AudioQueuePrime(is->outAQ, inNumberOfFramesToPrepare, 0);
	assert(err == 0);
	
	//
	err = AudioQueueStart(is->outAQ, NULL);
	assert(err == 0);
}

void LAVPAudioQueueStop(VideoState *is)
{
	//NSLog(@"LAVPAudioQueueStop");
	
	OSStatus err = 0;
	err = AudioQueueStop(is->outAQ, NO);
	assert(err == 0);
}

void LAVPAudioQueueDealloc(VideoState *is)
{
	//NSLog(@"LAVPAudioQueueDealloc");
	
	OSStatus err = 0;
	err = AudioQueueDispose(is->outAQ, YES);
	assert(err == 0);
	
	is->outAQ = NULL;
}
