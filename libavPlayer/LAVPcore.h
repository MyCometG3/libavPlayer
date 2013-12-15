/*
 *  LAVPcore.h
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

#ifndef __LAVPcore_h__
#define __LAVPcore_h__

#include "LAVPcommon.h"

double get_clock(Clock *c);
void set_clock_at(Clock *c, double pts, int serial, double time);
void set_clock(Clock *c, double pts, int serial);
void set_clock_speed(Clock *c, double speed);
void init_clock(Clock *c, volatile int *queue_serial);
void sync_clock_to_slave(Clock *c, Clock *slave);
int get_master_sync_type(VideoState *is);
double get_master_clock(VideoState *is);
void check_external_clock_speed(VideoState *is);

void stream_seek(VideoState *is, int64_t pos, int64_t rel, int seek_by_bytes);
void stream_toggle_pause(VideoState *is);
void toggle_pause(VideoState *is);

void stream_pause(VideoState *is);

void stream_close(VideoState *is);
VideoState* stream_open(id opaque, NSURL *sourceURL);
double_t stream_playRate(VideoState *is);
void stream_setPlayRate(VideoState *is, double_t newRate);

#endif