//
//  LAVPDecoder.m
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

#import "LAVPDecoder.h"

extern double get_master_clock(VideoState *is);
extern void stream_seek(VideoState *is, int64_t pos, int64_t rel, int seek_by_bytes);
extern void stream_pause(VideoState *is);
extern void stream_close(VideoState *is);
extern VideoState* stream_open(id opaque, NSURL *sourceURL);
extern void alloc_picture(void *opaque);
extern void video_refresh_timer(void *opaque);
extern int hasImage(void *opaque, double_t targetpts);
extern int copyImage(void *opaque, double_t targetpts, uint8_t* data, const int pitch) ;
extern int hasImageCurrent(void *opaque);
extern int copyImageCurrent(void *opaque, double_t *targetpts, uint8_t* data, int pitch) ;

#pragma mark -

@interface LAVPDecoder (internal)

- (void) allocPicture;

@end


@implementation LAVPDecoder

@synthesize is;
@synthesize abort;

- (id) initWithURL:(NSURL *)sourceURL error:(NSError **)errorPtr
{
	self = [super init];
	if (self) {
		is = stream_open(self, sourceURL);
		if (is) {
			[NSThread detachNewThreadSelector:@selector(threadMain) toTarget:self withObject:nil];
			
			int retry = 100;
			while(retry--) {
				usleep(10 * 1000);
				//if (is->width * is->height) break;
				if (is->pictq_size) break;
			}
			stream_pause(is);
		} else {
			[self release];
			self = nil;
		}
	}
	
	return self;
}

- (void) dealloc
{
	stream_close(is);
	self.abort = YES;
	[NSThread sleepForTimeInterval:0.1];
	CVPixelBufferRelease(pb);
	[super dealloc];
}

- (void) threadMain
{
	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	
	// Prepare thread runloop
	NSRunLoop* runLoop = [NSRunLoop currentRunLoop];
	
	self.is->decoderThread = [NSThread currentThread];
	
	NSTimer *timer = [NSTimer scheduledTimerWithTimeInterval:1.0/60 
													  target:self 
													selector:@selector(refreshPicture) 
													userInfo:nil 
													 repeats:YES];
	
	// 
	while ( self.abort != YES ) {
		NSAutoreleasePool *p = [NSAutoreleasePool new];
		
		[runLoop runUntilDate:[NSDate dateWithTimeIntervalSinceNow:0.1]];
		
		[p drain];
	}
	NSLog(@"abort");
	[timer invalidate];
	
	[pool drain];
}

- (void) allocPicture
{
	alloc_picture(is);
}

- (void) refreshPicture
{
	video_refresh_timer(is);
}

- (CVPixelBufferRef) createDummyCVPixelBufferWithSize:(NSSize)size {
	OSType format = '2vuy';	//k422YpCbCr8CodecType
	size_t width = size.width, height = size.height;
	CFDictionaryRef attr = NULL;
	CVPixelBufferRef pixelbuffer = NULL;
	
	assert(width * height > 0);
	CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, 
										  width, height, format, attr, &pixelbuffer);
	assert (result == kCVReturnSuccess && pixelbuffer);
	
	return pixelbuffer;
}

- (BOOL) readyForPTS:(double_t)pts
{
	if (hasImage(is, pts)) {
		return YES;
	}
	return NO;
}

- (CVPixelBufferRef) getPixelBufferForPTS:(double_t)pts
{
	if (!pb) {
		pb = [self createDummyCVPixelBufferWithSize:NSMakeSize(is->width, is->height)];
	}
	
	/* Get current buffer for pts */
	CVPixelBufferLockBaseAddress(pb, 0);
	
	uint8_t* data = CVPixelBufferGetBaseAddress(pb);
	int pitch = CVPixelBufferGetBytesPerRow(pb);
	int ret = copyImage(is, pts, data, pitch);
	
	CVPixelBufferUnlockBaseAddress(pb, 0);
	
	if (ret == 1) {
		return pb;
	}
	return NULL;
}

- (BOOL) readyForCurrent
{
	if (hasImageCurrent(is)) {
		return YES;
	}
	return NO;
}

- (CVPixelBufferRef) getPixelBufferForCurrent:(double_t*)pts
{
	if (!pb) {
		pb = [self createDummyCVPixelBufferWithSize:NSMakeSize(is->width, is->height)];
	}
	
	double_t currentpts=0.0;
	
	/* Get current buffer for pts */
	CVPixelBufferLockBaseAddress(pb, 0);
	
	uint8_t* data = CVPixelBufferGetBaseAddress(pb);
	int pitch = CVPixelBufferGetBytesPerRow(pb);
	int ret = copyImageCurrent(is, &currentpts, data, pitch);
	
	CVPixelBufferUnlockBaseAddress(pb, 0);
	
	if (ret == 1) {
		*pts = currentpts;
		return pb;
	}
	return NULL;
}

- (NSSize) frameSize
{
	NSSize size = NSMakeSize(is->width, is->height);
	//NSLog(@"size = %@", NSStringFromSize(size));
	return size;
}

- (void) play
{
	if (is && is->paused) {
		stream_pause(is);
	}
}

- (void) stop
{
	if (is && !is->paused) {
		stream_pause(is);
	}
}

- (CGFloat) rate
{
	if (is && is->paused) 
		return 0.0f;
	else if (is && is->ic && is->ic->duration <= 0)
		return 0.0f;
	else
		return 1.0f;
}

- (void) setRate:(CGFloat)rate
{
	if (rate > 0) {
		[self play];
	} else {
		[self stop];
	}
}

- (int64_t) duration
{
	// returned duration is in AV_TIME_BASE value.
	// avutil.h defines timebase for AVFormatContext - in usec.
	//#define AV_TIME_BASE            1000000
	
	if (is && is->ic) {
		return is->ic->duration;
	}
	return 0;
}

- (int64_t) position
{
	int64_t ts = 0;
	if (is && is->ic) {
		ts = get_master_clock(is);
		return ts;
	}
	return 0;
}

- (int64_t) setPosition:(int64_t)pos
{
	// clipping
	int64_t ts = FFMIN(is->ic->duration , FFMAX(0, pos));
	
	if (is->ic->start_time != AV_NOPTS_VALUE)
		ts += is->ic->start_time;
	
	stream_seek(is, ts, 0, 0);
	return ts;
}


@end
