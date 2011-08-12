//
//  LAVPthread.c
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

#include "LAVPthread.h"
#include "stdlib.h"
#include <assert.h>

void LAVPCondWait(LAVPcond *cond, LAVPmutex *mutex)
{
	//assert(cond);
	
	pthread_cond_wait(cond, mutex);
}

void LAVPCondSignal(LAVPcond *cond)
{
	//assert(cond);
	
	pthread_cond_signal(cond);
}

void LAVPDestroyCond(LAVPcond *cond)
{
	//assert(cond);
	
	pthread_cond_destroy(cond);
	free(cond);
}

LAVPcond* LAVPCreateCond()
{
	LAVPcond *cond = calloc(1, sizeof(pthread_cond_t));
	int result = pthread_cond_init(cond, NULL);
	assert(!result);
	return cond;
}

void LAVPLockMutex(LAVPmutex *mutex){
	//assert(mutex);
	
	pthread_mutex_lock(mutex);
}

void LAVPUnlockMutex(LAVPmutex *mutex)
{
	//assert(mutex);
	
	pthread_mutex_unlock(mutex);
}

void LAVPDestroyMutex(LAVPmutex *mutex)
{
	//assert(mutex);
	
	pthread_mutex_destroy(mutex);
	free(mutex);
}

LAVPmutex* LAVPCreateMutex()
{
	LAVPmutex *mutex = calloc(1, sizeof(pthread_mutex_t));
	int result = pthread_mutex_init(mutex, NULL);
	assert(!result);
	return mutex;
}

