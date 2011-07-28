//
//  LAVPDecoder.h
//  libavPlayer
//
//  Created by Takashi Mochizuki on 11/06/18.
//  Copyright 2011 MyCometG3. All rights reserved.
//
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

#import <Cocoa/Cocoa.h>

#include "LAVPCommon.h"

@interface LAVPDecoder : NSObject {
	NSString *path;
	
	VideoState *is;
	BOOL abort;
	
	CVPixelBufferRef pb;
}

@property (assign) VideoState *is;
@property (assign) BOOL abort;

- (id) initWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr;
- (void) threadMain;

- (BOOL) readyForPTS:(double_t)pts;
- (CVPixelBufferRef) getPixelBufferForPTS:(double_t)pts;
- (BOOL) readyForCurrent;
- (CVPixelBufferRef) getPixelBufferForCurrent:(double_t*)pts;
- (NSSize) frameSize;

- (void) play;
- (void) stop;
- (CGFloat) rate;
- (void) setRate:(CGFloat)rate;
- (int64_t) duration;
- (int64_t) position;
- (int64_t) setPosition:(int64_t)pos;
@end
