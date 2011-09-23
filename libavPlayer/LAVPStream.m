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
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#import "LAVPStream.h"
#import "LAVPDecoder.h"

NSString * const LAVPStreamDidEndNotification = @"LAVPStreamDidEndNotification";
NSString * const LAVPStreamDidSeekNotification = @"LAVPStreamDidSeekNotification";

#define AV_TIME_BASE            1000000

@implementation LAVPStream
@synthesize url;
@synthesize busy = _busy;

- (id) initWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr
{
	self = [super init];
	if (self) {
		url = [sourceURL copy];
		_htOffset = CVGetCurrentHostTime();
		currentVol = 1.0;
		
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
	[timer invalidate];
	timer = nil;
	
	[decoder invalidate];
	[decoder release];
	decoder = nil;
	
	[url release];
	url = nil;
}

- (void) finalize
{
	[self invalidate];
	
	[super finalize];
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
	
	//
	return [decoder readyForPTS:position];
}

- (CVPixelBufferRef) getCVPixelBufferForCurrentAsPTS:(double_t *)pts;
{
	*pts = -1.0;
	CVPixelBufferRef pb = [decoder getPixelBufferForCurrent:pts];
	return pb;
}

- (CVPixelBufferRef) getCVPixelBufferForTime:(const CVTimeStamp*)ts asPTS:(double_t *)pts;
{
	int64_t	duration = [decoder duration];
	uint64_t htDiff = ts->hostTime - _htOffset;
	double_t position = (double_t)htDiff / CVGetHostClockFrequency() + _posOffset * duration;
	
	// clipping
	position = (position < 0 ? 0 : position);
	position = (position > duration ? duration : position);
	
	//
	CVPixelBufferRef pb = [decoder getPixelBufferForPTS:position];
	if (pb) *pts = position;
	return pb;
}

- (QTTime) duration;
{
	int64_t	duration = [decoder duration];	//usec
	
	return QTMakeTime(duration, AV_TIME_BASE);
}

- (QTTime) currentTime
{
	int64_t position = [decoder position];	//usec
	
	return QTMakeTime(position, AV_TIME_BASE);
}

- (void) setCurrentTime:(QTTime)newTime
{
	QTTime timeInUsec = QTMakeTimeScaled(newTime, AV_TIME_BASE);
	
	[decoder setPosition:timeInUsec.timeValue blocking:YES];
}

- (double_t) position
{
	// position uses double value between 0.0 and 1.0
	
	int64_t position = [decoder position];	//usec
	int64_t	duration = [decoder duration];	//usec
	
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
	// position uses double value between 0.0 and 1.0
	
	//NSLog(@"seek start");
	
	int64_t	duration = [decoder duration];	//usec
	
	// clipping
	newPosition = (newPosition<0.0 ? 0.0 : newPosition);
	newPosition = (newPosition>1.0 ? 1.0 : newPosition);
	
	BOOL muted = [self muted];
	if (!muted) [self setMuted:YES];
	
	self.busy = YES;
	
	double_t prevRate = [self rate];
	BOOL seekExactly = (prevRate == 0 ? YES : NO);
	
	[decoder setPosition:newPosition*duration blocking:seekExactly];
	
	if (prevRate) [self setRate:prevRate];
	
	if (prevRate) usleep(125*1000);	// give some time to prepare new image
	
	self.busy = NO;
	
	if (!muted) [self setMuted:NO];
	
	//NSLog(@"seek finished");
	
	// Post notification
	//NSLog(@"LAVPStreamDidEndNotification");
	NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
	NSNotification *notification = [NSNotification notificationWithName:LAVPStreamDidSeekNotification
																 object:self];
	[center postNotification:notification];
}

- (double_t) rate
{
	double_t rate = [decoder rate];
	return rate;
}

- (void) setRate:(double_t) newRate
{
	//NSLog(@"setRate: %.3f at %.3f", newRate, [decoder position]/1.0e6);
	
	// stop notificatino timer
	if (timer) {
		[timer invalidate];
		timer = nil;
	}
	
	// pause first
	if ([decoder rate]) [decoder setRate:0.0];
	
	if (newRate != 0.0) {
		[decoder setRate:newRate];
		
		// current host time
		_htOffset = CVGetCurrentHostTime();
		
		// setup EndOfMovie Checker
		timer = [NSTimer scheduledTimerWithTimeInterval:0.1
												 target:self 
											   selector:@selector(checkEndOfMovie) 
											   userInfo:nil 
												repeats:YES];
	}
}

- (void)checkEndOfMovie
{
	if ([decoder eof] && [decoder rate] == 0.0) {
		//NSLog(@"movieFinished");
		
		// stop notificatino timer
		if (timer) {
			[timer invalidate];
			timer = nil;
		}
		
		// Post notification
		//NSLog(@"LAVPStreamDidEndNotification");
		NSNotificationCenter *center = [NSNotificationCenter defaultCenter];
		NSNotification *notification = [NSNotification notificationWithName:LAVPStreamDidEndNotification
																	 object:self];
		[center postNotification:notification];
	}
	
	return;
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

- (Float32) volume
{
	return currentVol;
}

- (void) setVolume:(Float32)volume
{
	currentVol = volume;
	if (!_muted)
		[decoder setVolume:volume];
}

- (BOOL) muted
{
	return _muted;
}

- (void) setMuted:(BOOL)muted
{
	if (muted) {
		_muted = TRUE;
		[decoder setVolume:0.0];
	} else {
		_muted = FALSE;
		[decoder setVolume:currentVol];
	}
}

- (BOOL) eof
{
	return [decoder eof];
}

@end
