/*
 *  LAVPqueue.h
 *  libavPlayer
 *
 *  Created by Takashi Mochizuki on 11/06/18.
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

#ifndef __LAVPqueue_h__
#define __LAVPqueue_h__

#include "LAVPcommon.h"

void packet_queue_init(PacketQueue *q);
void packet_queue_flush(PacketQueue *q);
void packet_queue_end(PacketQueue *q);
int packet_queue_put(PacketQueue *q, AVPacket *pkt);
void packet_queue_abort(PacketQueue *q);
int packet_queue_get(PacketQueue *q, AVPacket *pkt, int block);

#endif