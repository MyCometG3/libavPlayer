//
//  LAVPView.m
//  libavPlayer
//
//  Created by Takashi Mochizuki on 11/06/19.
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

#import "LAVPView.h"

@interface LAVPView (private)

- (uint64_t)startCVDisplayLink;
- (uint64_t)stopCVDisplayLink;
- (CVReturn)getFrameForTime:(const CVTimeStamp*)outputTime;

- (void) drawImage ;
- (CVPixelBufferRef) createDummyCVPixelBufferWithSize:(NSSize)size ;

- (CVPixelBufferRef) getCVPixelBuffer;
- (void) setCVPixelBuffer:(CVPixelBufferRef) pb;

@end

@implementation LAVPView
@synthesize expandToFit = _expandToFit;
@synthesize stream = _stream;

static CVReturn MyDisplayLinkCallback(CVDisplayLinkRef displayLink, 
									  const CVTimeStamp* now, 
									  const CVTimeStamp* outputTime, 
									  CVOptionFlags flagsIn, 
									  CVOptionFlags* flagsOut, 
									  void* displayLinkContext)
{
	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	CVReturn result = [(LAVPView*)displayLinkContext getFrameForTime:outputTime];
	[pool drain];
	
	return result;
}

- (uint64_t)startCVDisplayLink
{
	CGLContextObj cglContext = [[self openGLContext] CGLContextObj];
	CGLPixelFormatObj cglPixelFormat = [[self pixelFormat] CGLPixelFormatObj];
	CVDisplayLinkSetCurrentCGDisplayFromOpenGLContext(displayLink, cglContext, cglPixelFormat);

	CVDisplayLinkStart(displayLink);
	return CVGetCurrentHostTime();
}

- (uint64_t)stopCVDisplayLink
{
	CVDisplayLinkStop(displayLink);
	return CVGetCurrentHostTime();
}

- (void) dealloc
{
    // Stop and Release the display link
	[self stopCVDisplayLink];
    CVDisplayLinkRelease(displayLink);
	[lock release];
	
	if (image) {
		[image release];
		image = NULL;
	}
	if (pixelbuffer) {
		CVPixelBufferRelease(pixelbuffer);
		pixelbuffer = NULL;
	}
	if (ciContext) {
		[ciContext release];
	}
	[super dealloc];
}

- (id)initWithFrame:(NSRect)frameRect
{
	NSOpenGLPixelFormat *pixelFormat;
	pixelFormat = [NSOpenGLView defaultPixelFormat];
	
	// Initialize NSOpenGLView using specified pixelFormat
	self = [super initWithFrame:frameRect pixelFormat:pixelFormat];
	
	if (self) {
		// Create Initial CVPixelBuffer and CIImage
		[self setCVPixelBuffer:NULL];
		
		// Turn on VBL syncing for swaps
		GLint syncVBL = 1;
		[[self openGLContext] setValues:&syncVBL forParameter:NSOpenGLCPSwapInterval];
		
		// Set default value
		_expandToFit = NO;
		
		// Create and start CVDisplayLink
		CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
		CVDisplayLinkSetOutputCallback(displayLink, &MyDisplayLinkCallback, self);
		
		lock = [[NSLock alloc] init];
		
		[self startCVDisplayLink];
	}
	
	return self;
}

- (CVReturn)getFrameForTime:(const CVTimeStamp*)ts
{
	if (_stream && !NSEqualSizes([_stream frameSize], NSZeroSize)) {
		CVPixelBufferRef pb = [_stream getCVPixelBufferForTime:ts];
		if (pb) {
			[self setCVPixelBuffer:pb];
			
			// Update Image
			[self setNeedsDisplay:YES];
			return kCVReturnSuccess;
		} else {
			//NSLog(@"LAVPView: getFrameForTime: CVPixelBuffer is not ready.");
		}
	} else {
		//NSLog(@"LAVPView: getFrameForTime: stream is not ready.");
	}
	
	return kCVReturnError;
}

- (void)drawRect:(NSRect)theRect
{
	//NSLog(@"drawRect:");
	
	// Update Image
	[self drawImage];
	
	// Finishing touch by super class
	[super drawRect:theRect];
}

#pragma mark NSOpenGLView

/*
 Set up performed only once 
 */
- (void)prepareOpenGL {
	// Clear to black.
	glClearColor(0.0f, 0.0f, 0.0f, 1.0f);
	
	// Setup blending function 
	glBlendFunc(GL_SRC_ALPHA, GL_ONE_MINUS_SRC_ALPHA);
	
	// Enable texturing 
	glEnable(GL_TEXTURE_RECTANGLE_ARB);
}

#pragma mark private

/*
 Draw CVImageBuffer into CGLContext
 */
- (void) drawImage {
	//
	if (!ciContext) {
		// Create CoreImage Context
		CGLContextObj cglContext = [[self openGLContext] CGLContextObj];
		CGLPixelFormatObj cglPixelFormat = [[self pixelFormat] CGLPixelFormatObj];
		ciContext = [[CIContext contextWithCGLContext:cglContext 
										  pixelFormat:cglPixelFormat 
										   colorSpace:NULL 
											  options:NULL
					  ] retain];
	}
	
	//
	NSSize srcSize = [image extent].size;
	NSSize dstSize = [self bounds].size;
	CGFloat ratio = 1.0f;
	GLsizei offsetW = 0, offsetH = 0;
	
	if (_expandToFit) {
		// Scale image to fit inside view
		float dstAspect = dstSize.width/dstSize.height;
		float srcAspect = srcSize.width/srcSize.height;
		if (dstAspect<srcAspect) {
			ratio = dstSize.width / srcSize.width;
			offsetH = (srcSize.height*ratio-dstSize.height)/2;
		} else {
			ratio = dstSize.height / srcSize.height;
			offsetW = (srcSize.width*ratio-dstSize.width)/2;
		}
	} else {
		// Center image inside view
		offsetW = (srcSize.width*ratio - dstSize.width)/2.0;
		offsetH = (srcSize.height*ratio - dstSize.height)/2.0;
	}
	
	// Set up canvas
	glViewport(0, 0, dstSize.width, dstSize.height);
	
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	glOrtho(offsetW, dstSize.width+offsetW, offsetH, dstSize.height+offsetH, -1, 1);
	glScalef(ratio, ratio, 1.0f);
	
    glMatrixMode(GL_MODELVIEW);    // select the modelview matrix
    glLoadIdentity();              // reset it
	
	glClearColor(0 , 0 , 0 , 1);
	glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	
	// Render CVImageBuffer into CGLContext
	[lock lock];
	[ciContext drawImage:image atPoint:CGPointZero fromRect:[image extent]];
	[lock unlock];
	
#if 0
	// Debug - checkered pattern
	const size_t unit = 40;
	glColor3f(0.5f, 0.5f, 0.5f);
	for (int x = 0; x<srcSize.width; x+=unit) 
		for (int y = 0; y<srcSize.height; y+=unit)
			if ((x + y)/unit & 1) 
				glRectd(x, y, x+unit, y+unit);
#endif
}

/* =============================================================================================== */
#pragma mark -
/* =============================================================================================== */

/*
 new CVPixelBuffer '2vuy' using specified size.
 Caller must call CVPixelBufferRelease() when available.
 */
- (CVPixelBufferRef) createDummyCVPixelBufferWithSize:(NSSize)size {
	OSType format = '2vuy';	//k422YpCbCr8CodecType
	size_t width = size.width, height = size.height;
	CFDictionaryRef attr = NULL;
	CVPixelBufferRef pb = NULL;
	
	CVReturn result = CVPixelBufferCreate(kCFAllocatorDefault, 
										  width, height, format, attr, &pb);
	
	assert (result == kCVReturnSuccess && pb);
	
#if 1
	// Dummy fill
	CVPixelBufferLockBaseAddress(pb, 0);
	char *p = CVPixelBufferGetBaseAddress(pb);
	size_t rowLength = CVPixelBufferGetBytesPerRow(pb);
	size_t rowCount = CVPixelBufferGetHeight(pb);
	{
	#if 1
		memset(p, 0, rowLength * rowCount);
	#else
		int row = 0;
		for (row = 0; row < rowCount; row++) {
			memset(p + row*rowLength, row & 0xff, rowLength);
		}
	#endif
	}
	CVPixelBufferUnlockBaseAddress(pb, 0);
#endif
	return pb;
}

- (CVPixelBufferRef) getCVPixelBuffer
{
	return pixelbuffer;
}

- (void) setCVPixelBuffer:(CVPixelBufferRef) pb
{
	[lock lock];
	
	if (image) {
		[image release];
		image = NULL;
	}
	if (pixelbuffer) {
		CVPixelBufferRelease(pixelbuffer);
		pixelbuffer = NULL;
	}
	
	// Replace current CVPixelBuffer with new one
	if (pb) {
		pixelbuffer = pb;
		CVPixelBufferRetain(pixelbuffer);
	} else {
		pixelbuffer = [self createDummyCVPixelBufferWithSize:([self bounds].size)];
	}
	
	// Replace current CIImage with new one
	image = [[CIImage imageWithCVImageBuffer:pixelbuffer] retain];
	
	[lock unlock];
}

@end
