/*
 *  LAVPvideo.h
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

#ifndef __LAVPvideo_h__
#define __LAVPvideo_h__

#include "LAVPcommon.h"

int video_open(VideoState *is);
double get_video_clock(VideoState *is);
void video_refresh_timer(void *opaque);
void alloc_picture(void *opaque);
int video_thread(void *arg);

void init_pts_correction(PtsCorrectionContext *ctx);
int64_t guess_correct_pts(PtsCorrectionContext *ctx, int64_t pts, int64_t dts);

#endif