//
//  LAVPStream.m
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
 
 livavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with xvidEncoder; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#import "LAVPStream.h"
#import "LAVPDecoder.h"

NSString * const LAVPStreamDidEndNotification = @"LAVPStreamDidEndNotification";

#define AV_TIME_BASE            1000000

@implementation LAVPStream
@synthesize url;

- (id) initWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr
{
	self = [super init];
	if (self) {
		url = [sourceURL copy];
		_htOffset = CVGetCurrentHostTime();
		
		//
		decoder = [[LAVPDecoder alloc] initWithURL:url error:errorPtr];
		if (!decoder) {
			[self release];
			self = nil;
		}
	}
	
	return self;
}

+ (id) streamWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr
{
	Class myClass = [self class];
	self = [[myClass alloc] initWithURL:sourceURL error:errorPtr];
	
	return [self autorelease];
}

- (void) invalidate
{
	// perform clean up
	[decoder release];
	decoder = nil;
	[url release];
	url = nil;
}

- (void) dealloc
{
	[self invalidate];
	[super dealloc];
}

#pragma mark -

- (NSSize) frameSize
{
	NSSize size = [decoder frameSize];
	return size;
}

- (BOOL) readyForCurrent
{
	return [decoder readyForCurrent];
}

- (BOOL) readyForTime:(const CVTimeStamp*)ts
{
	int64_t	duration = [decoder duration];
	uint64_t htDiff = ts->hostTime - _htOffset;
	double_t position = (double_t)htDiff / CVGetHostClockFrequency() + _posOffset * duration;
	
	// clipping
	position = (position < 0 ? 0 : position);
	position = (position > duration ? duration : position);
	
	return [decoder readyForPTS:position];
}

- (CVPixelBufferRef) getCVPixelBufferForCurrent
{
	double pts = -1.0;
	CVPixelBufferRef pb = [decoder getPixelBufferForCurrent:&pts];
	return pb;
}

- (CVPixelBufferRef) getCVPixelBufferForTime:(const CVTimeStamp*)ts
{
	int64_t	duration = [decoder duration];
	uint64_t htDiff = ts->hostTime - _htOffset;
	double_t position = (double_t)htDiff / CVGetHostClockFrequency() + _posOffset * duration;
	
	// clipping
	position = (position < 0 ? 0 : position);
	position = (position > duration ? duration : position);
	
	CVPixelBufferRef pb = [decoder getPixelBufferForPTS:position];
	return pb;
}

- (double_t) duration
{
	// returns total movie duratino in sec
	int64_t	duration = [decoder duration];
	
	return (double_t)duration / AV_TIME_BASE;
}

- (double_t) position
{
	// LACPStream uses double value between 0.0 and 1.0
	// LAVPDecoder uses integer position / duration in AVFormatContext
	
	int64_t position = [decoder position];
	int64_t	duration = [decoder duration];
	
	// check if no duration
	if (duration == 0) return 0;
	
	// clipping
	position = (position < 0 ? 0 : position);
	position = (position > duration ? duration : position);
	
	// 
	return (double_t)position/duration;
}

- (void) setPosition:(double_t)newPosition
{
	// LACPStream uses double value between 0.0 and 1.0
	// LAVPDecoder uses integer position / duration in AVFormatContext
	
	int64_t	duration = [decoder duration];
	
	// clipping
	newPosition = (newPosition<0.0 ? 0.0 : newPosition);
	newPosition = (newPosition>1.0 ? 1.0 : newPosition);
	
	// 
	[decoder setPosition:newPosition*duration];
}

- (double_t) rate
{
	return _rate;
}

- (void) setRate:(double_t) newRate
{
	if (timer) {
		[timer invalidate];
		timer = nil;
	}
	
	if (newRate == 0.0) [decoder stop];
	
	// current host time
	_htOffset = CVGetCurrentHostTime();
	
	// update position
	int64_t position = [decoder position];
	int64_t	duration = [decoder duration];
	_posOffset = (double_t)position/duration;
	
	if (newRate != 0.0) {
		[decoder play];
		
		//
		double_t remain=1;
		if (newRate > 0.0) {
			remain = (double_t)(duration - position)/duration * AV_TIME_BASE;
		} else if (_rate < 0.0) {
			remain = (double_t)position/duration * AV_TIME_BASE;
		}
		timer = [NSTimer scheduledTimerWithTimeInterval:remain 
												 target:self 
											   selector:@selector(movieFinished) 
											   userInfo:nil 
												repeats:NO];
	}
	
	// update rate
	_rate = newRate;
}

- (void)movieFinished
{
	[self stop];
	
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	NSNotification *notification = [NSNotification notificationWithName:LAVPStreamDidEndNotification
																 object:self];
	[center postNotification:notification];
}

- (void) play
{
	[self setRate:1.0];
}

- (void) stop
{
	[self setRate:0.0];
}

- (void) gotoBeggining
{
	[self setPosition:0.0];
}

- (void) gotoEnd
{
	[self setPosition:1.0];
}

@end
