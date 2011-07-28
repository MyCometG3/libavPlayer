//
//  LAVPthread.c
//  libavPlayer
//
//  Created by Takashi Mochizuki on 11/07/27.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

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

