//
//  LAVPthread.h
//  libavPlayer
//
//  Created by Takashi Mochizuki on 11/07/27.
//  Copyright 2011 MyCometG3. All rights reserved.
//
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

#ifndef __LAVPthread_h__
#define __LAVPthread_h__

#include <pthread.h>

typedef pthread_cond_t LAVPcond;
typedef pthread_mutex_t LAVPmutex;

LAVPcond* LAVPCreateCond(void);
void LAVPDestroyCond(LAVPcond *cond);
void LAVPCondWait(LAVPcond *cond, LAVPmutex *mutex);
void LAVPCondSignal(LAVPcond *cond);

LAVPmutex* LAVPCreateMutex(void);
void LAVPDestroyMutex(LAVPmutex *mutex);
void LAVPLockMutex(LAVPmutex *mutex);
void LAVPUnlockMutex(LAVPmutex *mutex);

#endif