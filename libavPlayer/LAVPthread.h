//
//  LAVPthread.h
//  libavPlayer
//
//  Created by Takashi Mochizuki on 11/07/27.
//  Copyright 2011 __MyCompanyName__. All rights reserved.
//

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