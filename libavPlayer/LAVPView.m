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
 
 livavPlayer is distributed in the hope that it will be useful,
 but WITHOUT ANY WARRANTY; without even the implied warranty of
 MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
 GNU General Public License for more details.
 
 You should have received a copy of the GNU General Public License
 along with libavPlayer; if not, write to the Free Software
 Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#import "LAVPView.h"
#import <GLUT/glut.h>
#import <OpenGL/gl.h>

#define DUMMY_W 640
#define DUMMY_H 480

@interface LAVPView (private)

- (uint64_t)startCVDisplayLink;
- (uint64_t)stopCVDisplayLink;

- (CVReturn)getFrameForTime:(const CVTimeStamp*)outputTime;

- (void) drawImage;
- (void) setCIContext;
- (void) setFBO;
- (void) renderCoreImageToFBO;
- (void) renderQuad;

- (CVPixelBufferRef) createDummyCVPixelBufferWithSize:(NSSize)size ;
- (CVPixelBufferRef) getCVPixelBuffer;
- (void) setCVPixelBuffer:(CVPixelBufferRef) pb;

@end

@implementation LAVPView
@synthesize expandToFit = _expandToFit;

static CVReturn MyDisplayLinkCallback(CVDisplayLinkRef displayLink, 
									  const CVTimeStamp* now, 
									  const CVTimeStamp* outputTime, 
									  CVOptionFlags flagsIn, 
									  CVOptionFlags* flagsOut, 
									  void* displayLinkContext)
{
	CVReturn result = kCVReturnError;
	
	NSAutoreleasePool *pool = [NSAutoreleasePool new];
	
	LAVPView* obj = (LAVPView*)displayLinkContext;
	double_t lastPTS = obj->lastPTS;
	double_t rate = [obj->_stream rate];
	
	if (lastPTS < 0 || rate) 
		result = [obj getFrameForTime:outputTime];
	
	[pool drain];
	
	return result;
}

- (void)windowChangedScreen:(NSNotification*)inNotification
{
	NSDictionary *dict = [[[self window] screen] deviceDescription];
	CGDirectDisplayID newDisplayID = (CGDirectDisplayID)[[dict objectForKey:@"NSScreenNumber"] unsignedIntValue];
	
	if ((newDisplayID != 0) && (currentDisplayID != newDisplayID)) {
		CVDisplayLinkSetCurrentCGDisplay(displayLink, newDisplayID);
		currentDisplayID = newDisplayID;
	}
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

- (void) finalize
{
    // Resign observer
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	// Stop and Release the display link first
	[self stopCVDisplayLink];
	CVDisplayLinkRelease(displayLink);
	
	// Release stream
	_stream = NULL;
	
	// Delete the texture and the FBO
	if (FBOid) {
		glDeleteTextures(1, &FBOTextureId);
		glDeleteFramebuffersEXT(1, &FBOid);
		FBOTextureId = 0;
		FBOid = 0;
	}
	
	lock = NULL;
	
	image = NULL;
	
	if (pixelbuffer) {
		CVPixelBufferRelease(pixelbuffer);
		pixelbuffer = NULL;
	}
	
	ciContext = NULL;
	
	[super finalize];
}

- (void) dealloc
{
    // Resign observer
	[[NSNotificationCenter defaultCenter] removeObserver:self];
	
	// Stop and Release the display link first
	[self stopCVDisplayLink];
	CVDisplayLinkRelease(displayLink);
	
	// Release stream
	if (_stream) {
		[_stream release];
		_stream = NULL;
	}
	
	// Delete the texture and the FBO
	if (FBOid) {
		glDeleteTextures(1, &FBOTextureId);
		glDeleteFramebuffersEXT(1, &FBOid);
		FBOTextureId = 0;
		FBOid = 0;
	}
	
	if (lock) {
		[lock release];
		lock = NULL;
	}
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
		ciContext = NULL;
	}
	
	[super dealloc];
}

- (id)initWithFrame:(NSRect)frameRect
{
	// FBO Support
	NSOpenGLPixelFormatAttribute attrs[] =
	{
		NSOpenGLPFAAccelerated,
		NSOpenGLPFANoRecovery,
		NSOpenGLPFADoubleBuffer,
		NSOpenGLPFAColorSize, 24,
		NSOpenGLPFAAlphaSize,  8,
		//NSOpenGLPFADepthSize, 32,	// no depth buffer
		NSOpenGLPFAMultisample,
		NSOpenGLPFASampleBuffers, 1,
		NSOpenGLPFASamples, 4,
		0
	};
	
	NSOpenGLPixelFormat *pixelFormat = [[[NSOpenGLPixelFormat alloc] initWithAttributes:attrs] autorelease];
	
	// Initialize NSOpenGLView using specified pixelFormat
	self = [super initWithFrame:frameRect pixelFormat:pixelFormat];
	
	if (self) {
		// Create Initial CVPixelBuffer and CIImage
		//[self setCVPixelBuffer:NULL];
		
		lock = [[NSLock alloc] init];
		lastPTS = -1;
		
		// Set default value
		_expandToFit = NO;
		
		// Turn on VBL syncing for swaps
		GLint syncVBL = 1;
		[[self openGLContext] setValues:&syncVBL forParameter:NSOpenGLCPSwapInterval];
		
		// Create and start CVDisplayLink
		CVDisplayLinkCreateWithActiveCGDisplays(&displayLink);
		CVDisplayLinkSetOutputCallback(displayLink, &MyDisplayLinkCallback, self);
		
		[self startCVDisplayLink];
		
		[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(windowChangedScreen:) name:NSWindowDidMoveNotification object:nil];
	}
	
	return self;
}

- (CVReturn)getFrameForTime:(const CVTimeStamp*)ts
{
	if (_stream && !NSEqualSizes([_stream frameSize], NSZeroSize)) {
		CVPixelBufferRef pb;
		double_t pts;
		
		pb = [_stream getCVPixelBufferForTime:ts asPTS:&pts];
		if (pb) {
			if (lastPTS == pts) {
				return kCVReturnError;
			}
			lastPTS = pts;
			
			[lock lock];
			[self setCVPixelBuffer:pb];
			[lock unlock];
			
			// With help of CVDisplayLink, we can use -display instead of setNeedsDisplay.
			[self display];
			
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
	[lock lock];
	
	// Update Image
	[self drawImage];
	
	// Finishing touch by super class
	[super drawRect:theRect];
	
	[lock unlock];
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
	
	// Check FBO Support
	const GLubyte* strExt = glGetString(GL_EXTENSIONS);
	GLboolean isFBO = gluCheckExtension((const GLubyte*)"GL_EXT_framebuffer_object", strExt);
	assert(isFBO == GL_TRUE);
}

#pragma mark private

/*
 Draw CVImageBuffer into CGLContext
 */
- (void) drawImage {
	if (_stream && !NSEqualSizes([_stream frameSize], NSZeroSize)) {
		// Prepare CIContext
		[self setCIContext];
		
		// Prepare new texture
		[self setFBO];
		
		// update texture with current CIImage
		[self renderCoreImageToFBO];
		
		// Render quad
		[self renderQuad];
		
	} else {
		NSSize dstSize = [self bounds].size;
		
		// Set up canvas
		glViewport(0, 0, dstSize.width, dstSize.height);
		
		glMatrixMode(GL_PROJECTION);
		glLoadIdentity();
		
		glMatrixMode(GL_MODELVIEW);    // select the modelview matrix
		glLoadIdentity();              // reset it
		
		glClearColor(0 , 0 , 0 , 1);
		glClear(GL_COLOR_BUFFER_BIT | GL_DEPTH_BUFFER_BIT);
	}
}

/* =============================================================================================== */
#pragma mark -
/* =============================================================================================== */

/*
 Check CIContext and recreate if required
 */
- (void) setCIContext
{
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
}

/*
 Set up FBO and new Texture
 */
- (void) setFBO
{
	if (!FBOid) {
		// create FBO object
		glGenFramebuffersEXT(1, &FBOid);
		assert(FBOid);
		
		// create texture
		glGenTextures(1, &FBOTextureId);
		assert(FBOTextureId);
		
		// Bind FBO
		GLint   savedFBOid = 0;
		glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &savedFBOid);
		glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, FBOid);
		
		// Bind texture
		glBindTexture(GL_TEXTURE_RECTANGLE_ARB, FBOTextureId);
		
		// Prepare GL_BGRA texture attached to FBO
		glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
		glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
		glTexParameteri(GL_TEXTURE_RECTANGLE_ARB, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
		
		glTexImage2D(GL_TEXTURE_RECTANGLE_ARB, 0, GL_RGBA, textureRect.size.width, textureRect.size.height, 
					 0, GL_BGRA, GL_UNSIGNED_INT_8_8_8_8_REV, NULL);
		
		// Attach texture to the FBO as its color destination
		glFramebufferTexture2DEXT(GL_FRAMEBUFFER_EXT, GL_COLOR_ATTACHMENT0_EXT, GL_TEXTURE_RECTANGLE_ARB, FBOTextureId, 0);
		
		// Make sure the FBO was created succesfully.
		GLenum status = glCheckFramebufferStatusEXT(GL_FRAMEBUFFER_EXT);
		if (GL_FRAMEBUFFER_COMPLETE_EXT != status) {
			NSLog(@"glFramebufferTexture2DEXT() failed! (0x%04x)", status);
			if (GL_FRAMEBUFFER_UNSUPPORTED_EXT == status) {
				NSLog(@"GL_FRAMEBUFFER_UNSUPPORTED_EXT");
			} else if (GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT_EXT == status) {
				NSLog(@"GL_FRAMEBUFFER_INCOMPLETE_ATTACHMENT_EXT");
			} else if (GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT_EXT == status) {
				NSLog(@"GL_FRAMEBUFFER_INCOMPLETE_MISSING_ATTACHMENT_EXT");
			}
			assert(GL_FRAMEBUFFER_COMPLETE_EXT != status);
		}
		
		// unbind texture
		glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);
		
		// unbind FBO 
		glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, savedFBOid);
	}
}

/*
 Render CoreImage into Texture
 */
- (void) renderCoreImageToFBO
{
	// Same approach; CoreImageGLTextureFBO - MyOpenGLView.m - renderCoreImageToFBO
	
	// Bind FBO 
	GLint   savedFBOid = 0;
	glGetIntegerv(GL_FRAMEBUFFER_BINDING_EXT, &savedFBOid);
	glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, FBOid);
	
	{
		// prepare canvas
		GLint width = (GLint)ceil(textureRect.size.width);
		GLint height = (GLint)ceil(textureRect.size.height);
		
		glViewport(0, 0, width, height);
		
		glMatrixMode(GL_PROJECTION);
		glLoadIdentity();
		
		glOrtho(0, width, 0, height, -1, 1);
		
		glMatrixMode(GL_MODELVIEW);
		glLoadIdentity();
		
		// clear
		glClear(GL_COLOR_BUFFER_BIT);
		
		// render CVImageBuffer into CGLContext // BUGGY //
		
		// Fails (expand single pixel to texture)
		//[ciContext drawImage:image atPoint:CGPointMake(0, 0) fromRect:[image extent]];
		//[ciContext drawImage:image inRect:textureRect fromRect:[image extent]];
		//[ciContext drawImage:image inRect:CGRectMake(0, 0, width, height) fromRect:[image extent]];
		
		// Works
		//[ciContext drawImage:image atPoint:CGPointMake(1, 1) fromRect:[image extent]];
		//[ciContext drawImage:image inRect:CGRectMake(0, 0, width-1, height-1) fromRect:[image extent]];
		//[ciContext drawImage:image inRect:CGRectMake(1, 1, width-2, height-2) fromRect:[image extent]];
		[ciContext drawImage:image inRect:CGRectMake(0.001, 0.001, width, height) fromRect:[image extent]];
		
#if 0
		// Debug - checkered pattern
		const size_t unit = 40;
		glColor3f(0.5f, 0.5f, 0.5f);
		for (int x = 0; x<textureRect.size.width; x+=unit) 
			for (int y = 0; y<textureRect.size.height; y+=unit)
				if ((x + y)/unit & 1) 
					glRectd(x, y, x+unit, y+unit);
#endif
	}
	
	// Unbind FBO 
	glBindFramebufferEXT(GL_FRAMEBUFFER_EXT, savedFBOid);
}

/*
 Draw quad with Texture
 */
- (void) renderQuad
{
	// Handle kCAGravity behavior
	CGSize tr, tl, br, bl;
	CGSize ls = [self bounds].size;
	CGSize vs = [_stream frameSize];
	CGFloat hRatio = vs.width / ls.width;
	CGFloat vRatio = vs.height / ls.height;
	CGFloat lAspect = ls.width/ls.height;
	CGFloat vAspect = vs.width/vs.height;
	
	if (_expandToFit) {
		//kCAGravityResizeAspect
		if (lAspect > vAspect) {	// Layer is wider aspect than video - Shrink horizontally
			tr = CGSizeMake( hRatio/vRatio, 1.0f);
			tl = CGSizeMake(-hRatio/vRatio, 1.0f);
			bl = CGSizeMake(-hRatio/vRatio,-1.0f);
			br = CGSizeMake( hRatio/vRatio,-1.0f);
		} else {					// Layer is narrow aspect than video - Shrink vertically
			tr = CGSizeMake( 1.0f, vRatio/hRatio);
			tl = CGSizeMake(-1.0f, vRatio/hRatio);
			bl = CGSizeMake(-1.0f,-vRatio/hRatio);
			br = CGSizeMake( 1.0f,-vRatio/hRatio);
		}
	} else {
		// The default value is kCAGravityResize
		tr = CGSizeMake( 1.0f, 1.0f);
		tl = CGSizeMake(-1.0f, 1.0f);
		bl = CGSizeMake(-1.0f,-1.0f);
		br = CGSizeMake( 1.0f,-1.0f);
	}
	
	/* ========================================================= */
	
	// Same approach; CoreImageGLTextureFBO - MyOpenGLView.m - renderScene
	
	// prepare canvas
	glViewport(0, 0, [self bounds].size.width, [self bounds].size.height);
	
	glMatrixMode(GL_PROJECTION);
	glLoadIdentity();
	
	glMatrixMode(GL_TEXTURE);
	glLoadIdentity();
	
	glScalef(textureRect.size.width, textureRect.size.height, 1.0f);
	
	glMatrixMode(GL_MODELVIEW);
	glLoadIdentity();
	
	// clear
	glClear(GL_COLOR_BUFFER_BIT);
	
	// Bind Texture
	glBindTexture(GL_TEXTURE_RECTANGLE_ARB, FBOTextureId);
	glTexEnvf(GL_TEXTURE_ENV, GL_TEXTURE_ENV_MODE, GL_REPLACE);
	
	//glPushMatrix();
	{
		// Draw simple quad with texture image
		glBegin(GL_QUADS);
		
		glTexCoord2f( 1.0f, 1.0f ); glVertex2f( tr.width, tr.height );
		glTexCoord2f( 0.0f, 1.0f ); glVertex2f( tl.width, tl.height );
		glTexCoord2f( 0.0f, 0.0f ); glVertex2f( bl.width, bl.height );
		glTexCoord2f( 1.0f, 0.0f ); glVertex2f( br.width, br.height );
		
		glEnd();
	}
	//glPopMatrix();
	
	// Unbind Texture
	glBindTexture(GL_TEXTURE_RECTANGLE_ARB, 0);
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
	
	assert(width * height > 0);
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
		memset(p, 128, rowLength * rowCount);
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
		CVPixelBufferRetain(pb);
		pixelbuffer = pb;
	} else {
		pixelbuffer = [self createDummyCVPixelBufferWithSize:NSMakeSize(DUMMY_W, DUMMY_H)];
	}
	
	// Replace current CIImage with new one
	image = [[CIImage imageWithCVImageBuffer:pixelbuffer] retain];
}


/* =============================================================================================== */
#pragma mark -
#pragma mark public
/* =============================================================================================== */

- (LAVPStream *) stream
{
	return _stream;
}

- (void) setStream:(LAVPStream *)newStream
{
	//
	[lock lock];
	[self stopCVDisplayLink];
	
	// Delete the texture and the FBO
	if (FBOid) {
		glDeleteTextures(1, &FBOTextureId);
		glDeleteFramebuffersEXT(1, &FBOid);
		FBOTextureId = 0;
		FBOid = 0;
	}
	
	//
	[_stream autorelease];
	_stream = [newStream retain];
	
	// Get the size of the image we are going to need throughout
	if (_stream && [_stream frameSize].width && [_stream frameSize].height)
		textureRect = CGRectMake(0, 0, [_stream frameSize].width, [_stream frameSize].height);
	else
		textureRect = CGRectMake(0, 0, DUMMY_W, DUMMY_H);
	
	// Get the aspect ratio for possible scaling (e.g. texture coordinates)
	imageAspectRatio = textureRect.size.width / textureRect.size.height;
	
	// Shrink texture size if it is bigger than limit
	GLint maxTexSize; 
	glGetIntegerv(GL_MAX_TEXTURE_SIZE, &maxTexSize);
	if (textureRect.size.width > maxTexSize || textureRect.size.height > maxTexSize) {
		if (imageAspectRatio > 1) {
			textureRect.size.width = maxTexSize; 
			textureRect.size.height = maxTexSize / imageAspectRatio;
		} else {
			textureRect.size.width = maxTexSize * imageAspectRatio ;
			textureRect.size.height = maxTexSize; 
		}
		//NSLog(@"texture rect = %@ (shrinked)", NSStringFromRect(textureRect));
	} else {
		//NSLog(@"texture rect = %@", NSStringFromRect(textureRect));
	}
	
	// Try to update NSOpenGLLayer
	lastPTS = -1;
	[self setNeedsDisplay:YES];
	
	//
	[self startCVDisplayLink];
	[lock unlock];
}

@end
