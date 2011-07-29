/*
 *  LAVPCommon.h
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

#ifndef __LAVPCommon_h__
#define __LAVPCommon_h__

#include "avcodec.h"
#include "avformat.h"
#include "avutil.h"
#include "swscale.h"

#include "libavcodec/audioconvert.h"
#include "libavcodec/avfft.h"
#include "libavutil/imgutils.h"
#include "libavutil/eval.h"
#include "libavutil/parseutils.h"
#include "libavutil/opt.h"
#include "libavutil/colorspace.h"

#include "LAVPthread.h"

#define ALLOW_GPL_CODE 1

/* =========================================================== */

enum {
    AV_SYNC_AUDIO_MASTER, /* default choice */
    AV_SYNC_VIDEO_MASTER,
    AV_SYNC_EXTERNAL_CLOCK, /* synchronize to an external clock */
};

#define AUDIO_DIFF_AVG_NB   20

#define AV_NOSYNC_THRESHOLD 10.0

#define VIDEO_PICTURE_QUEUE_SIZE 2

#define SUBPICTURE_QUEUE_SIZE 4

/* =========================================================== */

typedef struct PacketQueue {
    AVPacketList *first_pkt, *last_pkt;
    int nb_packets;
    int size;
    int abort_request;
    LAVPmutex *mutex;
    LAVPcond *cond;
	
	AVPacket flush_pkt;
} PacketQueue;

typedef struct PtsCorrectionContext {
    int64_t num_faulty_pts; /// Number of incorrect PTS values so far
    int64_t num_faulty_dts; /// Number of incorrect DTS values so far
    int64_t last_pts;       /// PTS of the last frame
    int64_t last_dts;       /// DTS of the last frame
} PtsCorrectionContext;

typedef struct VideoPicture {
    double pts;                                  ///<presentation time stamp for this picture
    double target_clock;                         ///<av_gettime() time at which this should be displayed ideally
    int64_t pos;                                 ///<byte position in file
    AVFrame *bmp;
    int width, height; /* source height & width */
    int allocated;
    enum PixelFormat pix_fmt;

} VideoPicture;

typedef struct SubPicture {
    double pts; /* presentation time stamp for this picture */
    AVSubtitle sub;
} SubPicture;

typedef struct VideoState {
	void *decoder;	// LAVPDecoder instance
	void *decoderThread;	// NSThread instance for decoderThread
	int abort_request;
	int show_status;
    
	AVFormatContext *ic;
	AVFormatContext *avformat_opts;
	
    enum AVSampleFormat audio_src_fmt;
	
    unsigned int audio_buf_size; /* in bytes */
    int audio_buf_index; /* in bytes */
    double audio_diff_avg_coef;
    double audio_diff_threshold;
    int audio_diff_avg_count;
    AVPacket audio_pkt;
    AVPacket audio_pkt_temp;
    AVAudioConvert *reformat_ctx;
	int64_t audio_callback_time;
    double audio_clock;
    double audio_diff_cum; /* used for AV difference average computation */
    DECLARE_ALIGNED(16,uint8_t,audio_buf1)[(AVCODEC_MAX_AUDIO_FRAME_SIZE * 3) / 2];
    DECLARE_ALIGNED(16,uint8_t,audio_buf2)[(AVCODEC_MAX_AUDIO_FRAME_SIZE * 3) / 2];
    uint8_t *audio_buf;
	
    int video_stream;
    int audio_stream;
    int subtitle_stream;
	
    AVStream *video_st;
    AVStream *audio_st;
    AVStream *subtitle_st;
	
    PacketQueue audioq;
    PacketQueue videoq;
    PacketQueue subtitleq;
	
	dispatch_queue_t parse_queue;
	dispatch_group_t parse_group;
	dispatch_queue_t video_queue;
	dispatch_group_t video_group;
	dispatch_queue_t subtitle_queue;
	dispatch_group_t subtitle_group;
	
    LAVPmutex *pictq_mutex;
    LAVPmutex *subpq_mutex;
    LAVPcond *pictq_cond;
    LAVPcond *subpq_cond;
	
	struct SwsContext *sws_opts;
    struct SwsContext *img_convert_ctx;
	int sws_flags;
	
    int subtitle_stream_changed;

	int seek_by_bytes;
	AVCodecContext *avcodec_opts[AVMEDIA_TYPE_NB];
	
	int loop;
    int av_sync_type;
    double external_clock; /* external clock base */
    int64_t external_clock_time;
	
	int step;
    int seek_req;
    int seek_flags;
    int64_t seek_pos;
    int64_t seek_rel;
    int paused;
    int last_paused;
    int read_pause_return;
	
    double frame_timer;
    double video_current_pts;                    ///<current displayed pts (different from video_clock if frame fifos are used)
    double video_current_pts_drift;              ///<video_current_pts - time (av_gettime) at which we updated video_current_pts - used to have running video pts
    double frame_last_pts;
    double frame_last_delay;
    double video_clock;                          ///<pts of last decoded frame / predicted pts of next decoded frame
    int64_t video_current_pos;                   ///<current displayed file pos
	int decoder_reorder_pts;
	
    int refresh;
    PtsCorrectionContext pts_ctx;
    float skip_frames;
    float skip_frames_index;
	
    int width, height, xleft, ytop;
    VideoPicture pictq[VIDEO_PICTURE_QUEUE_SIZE];
    int pictq_size, pictq_rindex, pictq_windex;
	
    SubPicture subpq[SUBPICTURE_QUEUE_SIZE];
    int subpq_size, subpq_rindex, subpq_windex;
	
	struct SwsContext *sws420to422;
	double lastPTScopied;
	
	//
	AudioQueueRef outAQ;
	AudioStreamBasicDescription asbd;
	dispatch_queue_t audioDispatchQueue;
} VideoState;

#endif