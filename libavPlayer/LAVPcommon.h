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
 
 livavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
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
#include "libavutil/time.h"
#include "libavutil/avstring.h"
#include "libswresample/swresample.h"

#include "LAVPthread.h"

#define ALLOW_GPL_CODE 1 /* LAVP: enable my pictformat code in GPL */

/* =========================================================== */

#define MAX_QUEUE_SIZE (15 * 1024 * 1024)
#define MIN_FRAMES 5

/* SDL audio buffer size, in samples. Should be small to have precise
 A/V sync as SDL does not have hardware buffer fullness info. */
#define SDL_AUDIO_BUFFER_SIZE 1024

/* no AV sync correction is done if below the minimum AV sync threshold */
#define AV_SYNC_THRESHOLD_MIN 0.01
/* AV sync correction is done if above the maximum AV sync threshold */
#define AV_SYNC_THRESHOLD_MAX 0.1
/* If a frame duration is longer than this, it will not be duplicated to compensate AV sync */
#define AV_SYNC_FRAMEDUP_THRESHOLD 0.1
/* no AV correction is done if too big error */
#define AV_NOSYNC_THRESHOLD 10.0

/* maximum audio speed change to get correct sync */
#define SAMPLE_CORRECTION_PERCENT_MAX 10

/* external clock speed adjustment constants for realtime sources based on buffer fullness */
#define EXTERNAL_CLOCK_SPEED_MIN  0.900
#define EXTERNAL_CLOCK_SPEED_MAX  1.010
#define EXTERNAL_CLOCK_SPEED_STEP 0.001

/* we use about AUDIO_DIFF_AVG_NB A-V differences to make the average */
#define AUDIO_DIFF_AVG_NB   20

/* polls for possible required screen refresh at least this often, should be less than 1/fps */
#define REFRESH_RATE 0.01

/* NOTE: the size must be big enough to compensate the hardware audio buffersize size */
/* TODO: We assume that a decoded and resampled frame fits into this buffer */
#define SAMPLE_ARRAY_SIZE (8 * 65536)

#define CURSOR_HIDE_DELAY 1000000

/* =========================================================== */

#define VIDEO_PICTURE_QUEUE_SIZE 15 /* LAVP: no-overrun patch in refresh_loop_wait_event() applied */
#define SUBPICTURE_QUEUE_SIZE 4

/* =========================================================== */

#define ALPHA_BLEND(a, oldp, newp, s)\
((((oldp << s) * (255 - (a))) + (newp * (a))) / (255 << s))

#define RGBA_IN(r, g, b, a, s)\
{\
unsigned int v = ((const uint32_t *)(s))[0];\
a = (v >> 24) & 0xff;\
r = (v >> 16) & 0xff;\
g = (v >> 8) & 0xff;\
b = v & 0xff;\
}

#define YUVA_IN(y, u, v, a, s, pal)\
{\
unsigned int val = ((const uint32_t *)(pal))[*(const uint8_t*)(s)];\
a = (val >> 24) & 0xff;\
y = (val >> 16) & 0xff;\
u = (val >> 8) & 0xff;\
v = val & 0xff;\
}

#define YUVA_OUT(d, y, u, v, a)\
{\
((uint32_t *)(d))[0] = (a << 24) | (y << 16) | (u << 8) | v;\
}

#define BPP 1

/* =========================================================== */

enum {
	AV_SYNC_AUDIO_MASTER, /* default choice */
	AV_SYNC_VIDEO_MASTER,
	AV_SYNC_EXTERNAL_CLOCK, /* synchronize to an external clock */
};

enum ShowMode {
    SHOW_MODE_NONE = -1, SHOW_MODE_VIDEO = 0, SHOW_MODE_WAVES, SHOW_MODE_RDFT, SHOW_MODE_NB
} show_mode;

/* =========================================================== */

typedef struct MyAVPacketList {
    AVPacket pkt;
    struct MyAVPacketList *next;
    volatile int serial;
} MyAVPacketList;

typedef struct PacketQueue {
	MyAVPacketList *first_pkt, *last_pkt;
	volatile int nb_packets;
	volatile int size;
	volatile int abort_request;
    volatile int serial;
	LAVPmutex *mutex;
	LAVPcond *cond;
	
	AVPacket flush_pkt; /* LAVP: assign queue specific flush packet */
} PacketQueue;

/* =========================================================== */

typedef struct VideoPicture {
    volatile double pts;             // presentation timestamp for this picture
    double duration;        // estimated duration based on frame rate
    int64_t pos;            // byte position in file
	AVFrame *bmp;
	volatile int width, height; /* source height & width */
	volatile int allocated;
    volatile int reallocate;
    volatile int serial;
    
    AVRational sar;
} VideoPicture;

typedef struct SubPicture {
	volatile double pts; /* presentation time stamp for this picture */
	AVSubtitle sub;
    volatile int serial;
} SubPicture;

typedef struct AudioParams {
    volatile int freq;
    volatile int channels;
    volatile int64_t channel_layout;
    enum AVSampleFormat fmt;
} AudioParams;

typedef struct Clock {
    volatile double pts;           /* clock base */
    volatile double pts_drift;     /* clock base minus time at which we updated the clock */
    volatile double last_updated;
    volatile double speed;
    volatile int serial;           /* clock is based on a packet with this serial */
    volatile int paused;
    volatile int *queue_serial;    /* pointer to the current packet queue serial, used for obsolete clock detection */
} Clock;

/* =========================================================== */

typedef struct VideoState {
    /* moved from global parameter */
    int64_t sws_flags;              /* static int64_t sws_flags = SWS_BICUBIC; */
    volatile int seek_by_bytes;     /* static int seek_by_bytes = -1; */
    int display_disable;            /* static int display_disable; */
	volatile int show_status;       /* static int show_status = -1 */
    int workaround_bugs;            /* static int workaround_bugs = 1; */
    int fast;                       /* static int fast = 0; */
    int genpts;                     /* static int genpts = 0; */
    int lowres;                     /* static int lowres = 0; */
    int error_concealment;          /* static int error_concealment = 3; */
	int decoder_reorder_pts;        /* static int decoder_reorder_pts = -1; */
	int loop;                       /* static int loop = 1; */
	int framedrop;                  /* static int framedrop = -1; */
    volatile int infinite_buffer;            /* static int infinite_buffer = -1; */
    volatile enum ShowMode show_mode;        /* static enum ShowMode show_mode = SHOW_MODE_NONE; */
    double rdftspeed;               /* double rdftspeed = 0.02; */
    
    volatile int64_t audio_callback_time;    /* static int64_t audio_callback_time; */
    
    /* moved from local valuable */
    volatile double remaining_time;
    
	// LAVPcore
    
    /* same order as original struct */
    AVInputFormat *iformat;
    //
	volatile int abort_request;
    volatile int force_refresh;
	volatile int paused;
	volatile int last_paused;
    volatile int queue_attachments_req;
    volatile int seek_req;
    volatile int seek_flags;
	volatile int64_t seek_pos;
	volatile int64_t seek_rel;
	volatile int read_pause_return;
	AVFormatContext *ic;
    volatile int realtime;
    volatile int audio_finished; /* AVPacket serial */
    volatile int video_finished; /* AVPacket serial */
    //
    Clock audclk;
    Clock vidclk;
    Clock extclk;
    //
	volatile int av_sync_type;
    //
    char* filename; /* LAVP: char filename[1024] */
    volatile int width, height, xleft, ytop;
	volatile int step;
    //
    LAVPcond *continue_read_thread;
	
    /* stream index */
	volatile int video_stream, audio_stream, subtitle_stream;
    volatile int last_video_stream, last_audio_stream, last_subtitle_stream;

    /* AVStream */
	AVStream *audio_st;
	AVStream *video_st;
	AVStream *subtitle_st;
	
    /* PacketQueue */
	PacketQueue audioq;
	PacketQueue videoq;
	PacketQueue subtitleq;
	
    /* Extension; playRate */
    double_t playRate;
    volatile int eof_flag;
    
    /* Extension; Sub thread */
	void* parse_queue; // dispatch_queue_t
	void* parse_group; // dispatch_group_t
	void* video_queue; // dispatch_queue_t
	void* video_group; // dispatch_group_t
	void* subtitle_queue; // dispatch_queue_t
	void* subtitle_group; // dispatch_group_t
    
    /* Extension; Obj-C Instance */
	void* decoder;  // LAVPDecoder*
	void* decoderThread;    // NSThread*
	
    /* =========================================================== */
    
	// LAVPaudio
    
    /* same order as original struct */
    volatile double audio_clock;
    volatile int audio_clock_serial;
    double audio_diff_cum; /* used for AV difference average computation */
    double audio_diff_avg_coef;
    double audio_diff_threshold;
    int audio_diff_avg_count;
    //
    int audio_hw_buf_size;
    uint8_t silence_buf[SDL_AUDIO_BUFFER_SIZE];
    uint8_t *audio_buf;
    uint8_t *audio_buf1;
    unsigned int audio_buf_size; /* in bytes */
    unsigned int audio_buf1_size;
    int audio_buf_index; /* in bytes */
    int audio_write_buf_size;
    int audio_buf_frames_pending;
    AVPacket audio_pkt_temp;
    AVPacket audio_pkt;
    int audio_pkt_temp_serial;
    int audio_last_serial;
    struct AudioParams audio_src;
#if 0
#endif
    struct AudioParams audio_tgt;
    struct SwrContext *swr_ctx;
    //
    AVFrame *frame;
    int64_t audio_frame_next_pts;

    /* video audio display support */
    int16_t sample_array[SAMPLE_ARRAY_SIZE];
    int sample_array_index;
    int last_i_start;
    RDFTContext *rdft;
    int rdft_bits;
    FFTSample *rdft_data;
    int xpos;
    double last_vis_time;
    
    /* LAVP: extension */
	AudioQueueRef outAQ;
	AudioStreamBasicDescription asbd;
	void* audioDispatchQueue; // dispatch_queue_t
    
    /* =========================================================== */
    
	// LAVPsubs

    /* same order as original struct */
    SubPicture subpq[SUBPICTURE_QUEUE_SIZE];
	volatile int subpq_size, subpq_rindex, subpq_windex;
	LAVPmutex *subpq_mutex;
	LAVPcond *subpq_cond;
    
    /* =========================================================== */

	// LAVPvideo
    
    /* same order as original struct */
    int frame_drops_early;
    int frame_drops_late;
    //
	volatile double frame_timer;
    volatile double frame_last_returned_time;
    volatile double frame_last_filter_delay;
    //
	volatile int64_t video_current_pos;      ///<current displayed file pos
    volatile double max_frame_duration;      // maximum duration of a frame - above this, we consider the jump a timestamp discontinuity
	VideoPicture pictq[VIDEO_PICTURE_QUEUE_SIZE];
	volatile int pictq_size, pictq_rindex, pictq_windex;
	LAVPmutex *pictq_mutex;
	LAVPcond *pictq_cond;
    struct SwsContext *img_convert_ctx;
    
    /* LAVP: extension */
	volatile double lastPTScopied;
	struct SwsContext *sws420to422;
	
    /* =========================================================== */
    
} VideoState;

#endif