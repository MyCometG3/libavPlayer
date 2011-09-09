//
//  LAVPLayer.m
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

#import "LAVPLayer.h"
#import <GLUT/glut.h>
#import <OpenGL/gl.h>

#define DUMMY_W 640
#define DUMMY_H 480

@interface LAVPLayer (private)

- (void) prepareOpenGL;

- (void) drawImage;
- (void) setCIContext;
- (void) setFBO;
- (void) renderCoreImageToFBO;
- (void) renderQuad;

- (CVPixelBufferRef) createDummyCVPixelBufferWithSize:(NSSize)size ;
- (CVPixelBufferRef) getCVPixelBuffer;
- (void) setCVPixelBuffer:(CVPixelBufferRef) pb;

@end

@implementation LAVPLayer

- (void) finalize
{
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
	
	gravities = NULL;
}

- (void) dealloc
{
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
	if (gravities) {
		[gravities release];
		gravities = NULL;
	}
	
	[super dealloc];
}

- (id) init
{
	self = [super init];
	
	if (self) {
		// kCAGravity support
		gravities = [[NSArray arrayWithObjects:
					  kCAGravityCenter,				//0
					  kCAGravityTop,				//1
					  kCAGravityBottom,				//2
					  kCAGravityLeft,				//3
					  kCAGravityRight,				//4
					  kCAGravityTopLeft,			//5
					  kCAGravityTopRight,			//6
					  kCAGravityBottomLeft,			//7
					  kCAGravityBottomRight,		//8
					  kCAGravityResize,				//9
					  kCAGravityResizeAspect, 		//10
					  kCAGravityResizeAspectFill,	//11
					  nil] retain];
		
		// FBO Support
		GLint numPixelFormats = 0;
		CGLPixelFormatAttribute attributes[] =
		{
			kCGLPFAAccelerated,
			kCGLPFANoRecovery,
			kCGLPFADoubleBuffer,
			kCGLPFAColorSize, 24,
			kCGLPFAAlphaSize,  8,
			//kCGLPFADepthSize, 16,	// no depth buffer
			kCGLPFAMultisample,
			kCGLPFASampleBuffers, 1,
			kCGLPFASamples, 4,
			0
		};
		
		CGLChoosePixelFormat(attributes, &_cglPixelFormat, &numPixelFormats);
		assert(_cglPixelFormat);
		
		_cglContext = [super copyCGLContextForPixelFormat:_cglPixelFormat];
		assert(_cglContext);
		
		// Force CGLContext
		CGLContextObj savedContext = CGLGetCurrentContext();
		CGLSetCurrentContext(_cglContext);
		CGLLockContext(_cglContext);
		
		// 
		[self prepareOpenGL];
		
		/* ========================================================= */
		
		// Create Initial CVPixelBuffer and CIImage
		//[self setCVPixelBuffer:NULL];
		
		lock = [[NSLock alloc] init];
		lastPTS = -1;
		
		// Turn on VBL syncing for swaps
		self.asynchronous = YES;
		
		// Update back buffer size as is
		self.needsDisplayOnBoundsChange = YES;
		
		// Restore CGLContext
		CGLUnlockContext(_cglContext);
		CGLSetCurrentContext(savedContext);
	}
	
	return self;
}

/* =============================================================================================== */
#pragma mark -
/* =============================================================================================== */

- (CGLPixelFormatObj) copyCGLPixelFormatForDisplayMask:(uint32_t)mask
{
	CGLRetainPixelFormat(_cglPixelFormat);
	return _cglPixelFormat;
}

- (void) releaseCGLPixelFormat:(CGLPixelFormatObj)pixelFormat
{
	CGLReleasePixelFormat(_cglPixelFormat);
}

- (CGLContextObj) copyCGLContextForPixelFormat:(CGLPixelFormatObj)pixelFormat
{
	CGLRetainContext(_cglContext);
	return _cglContext;
}

- (void) releaseCGLContext:(CGLContextObj)glContext
{
	CGLReleaseContext(_cglContext);
}

- (BOOL) canDrawInCGLContext:(CGLContextObj)glContext 
				 pixelFormat:(CGLPixelFormatObj)pixelFormat 
				forLayerTime:(CFTimeInterval)timeInterval 
				 displayTime:(const CVTimeStamp *)timeStamp
{
	if (!_stream) return NO;
	if (NSEqualSizes([_stream frameSize], NSZeroSize)) return NO;
	
#if 0
	return YES;
#endif
	
	if (!CGRectEqualToRect(prevRect, [self bounds])) {
		prevRect = [self bounds];
		return YES;
	}
	
	if (!timeStamp) 
		return [_stream readyForCurrent];
	else
		return [_stream readyForTime:timeStamp];
}

- (void) drawInCGLContext:(CGLContextObj)glContext 
			  pixelFormat:(CGLPixelFormatObj)pixelFormat 
			 forLayerTime:(CFTimeInterval)timeInterval 
			  displayTime:(const CVTimeStamp *)timeStamp
{
	[lock lock];
	
	// Prepare CIImage
	if (_stream && !NSEqualSizes([_stream frameSize], NSZeroSize)) {
		CVPixelBufferRef pb;
		double_t pts;
		
		if (!timeStamp) 
			pb = [_stream getCVPixelBufferForCurrentAsPTS:&pts];
		else
			pb = [_stream getCVPixelBufferForTime:timeStamp asPTS:&pts];
		if (pb) {
			lastPTS = pts;
			
			[self setCVPixelBuffer:pb];
		}
	}
	
	// Update texture and draw quad
	[self drawImage];
	
	// Finishing touch by super class
	[super drawInCGLContext:glContext 
				pixelFormat:pixelFormat 
			   forLayerTime:timeInterval 
				displayTime:timeStamp];
	
	[lock unlock];
}

/* =============================================================================================== */
#pragma mark -
#pragma mark private
/* =============================================================================================== */

/*
 Set up performed only once 
 */
- (void) prepareOpenGL {
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

/*
 Draw CVImageBuffer into CGLContext
 */
- (void) drawImage {
	//
	CGLContextObj savedContext = CGLGetCurrentContext();
	CGLSetCurrentContext(_cglContext);
	CGLLockContext(_cglContext);
	
	/* ========================================================= */
	
	//	GLint  viewport[ 4 ];
	
	//	// Preserve matrices
	//	glGetIntegerv( GL_VIEWPORT, viewport );
	//	glMatrixMode( GL_PROJECTION );
	//	glPushMatrix();
	//	glMatrixMode( GL_MODELVIEW );
	//	glPushMatrix();
	
	/* ========================================================= */
	
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
	
	/* ========================================================= */
	
	//	// Restore matrices
	//	glViewport( viewport[ 0 ], viewport[ 1 ], viewport[ 2 ], viewport[ 3 ] );
	//	glMatrixMode( GL_PROJECTION );
	//	glPopMatrix();
	//	glMatrixMode( GL_MODELVIEW );
	//	glPopMatrix();
	
	/* ========================================================= */
	
	// 
	CGLUnlockContext(_cglContext);
	CGLSetCurrentContext(savedContext);
}

/*
 Check CIContext and recreate if required
 */
- (void) setCIContext
{
	if (!ciContext) {
		// Create CoreImage Context
		ciContext = [[CIContext contextWithCGLContext:_cglContext 
										  pixelFormat:_cglPixelFormat 
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
	CGFloat vOffset = 1.0f - (1.0f-vRatio)*2 ;
	CGFloat hOffset = 1.0f - (1.0f-hRatio)*2 ;
	
	switch ([gravities indexOfObject:self.contentsGravity]) {
		case 0: //kCAGravityCenter
			tr = CGSizeMake( hRatio, vRatio);
			tl = CGSizeMake(-hRatio, vRatio);
			bl = CGSizeMake(-hRatio,-vRatio);
			br = CGSizeMake( hRatio,-vRatio);
			break;
		case 1: //kCAGravityTop
			tr = CGSizeMake( hRatio, 1.0f);
			tl = CGSizeMake(-hRatio, 1.0f);
			bl = CGSizeMake(-hRatio,-vOffset);
			br = CGSizeMake( hRatio,-vOffset);
			break;
		case 2: //kCAGravityBottom
			tr = CGSizeMake( hRatio, vOffset);
			tl = CGSizeMake(-hRatio, vOffset);
			bl = CGSizeMake(-hRatio,-1.0f);
			br = CGSizeMake( hRatio,-1.0f);
			break;
		case 3: //kCAGravityLeft
			tr = CGSizeMake( hOffset, vRatio);
			tl = CGSizeMake(-1.0f, vRatio);
			bl = CGSizeMake(-1.0f,-vRatio);
			br = CGSizeMake( hOffset,-vRatio);
			break;
		case 4: //kCAGravityRight
			tr = CGSizeMake( 1.0f, vRatio);
			tl = CGSizeMake(-hOffset, vRatio);
			bl = CGSizeMake(-hOffset,-vRatio);
			br = CGSizeMake( 1.0f,-vRatio);
			break;
		case 5: //kCAGravityTopLeft
			tr = CGSizeMake( hOffset, 1.0f);
			tl = CGSizeMake(-1.0f, 1.0f);
			bl = CGSizeMake(-1.0f,-vOffset);
			br = CGSizeMake( hOffset,-vOffset);
			break;
		case 6: //kCAGravityTopRight
			tr = CGSizeMake( 1.0f, 1.0f);
			tl = CGSizeMake(-hOffset, 1.0f);
			bl = CGSizeMake(-hOffset,-vOffset);
			br = CGSizeMake( 1.0f,-vOffset);
			break;
		case 7: //kCAGravityBottomLeft
			tr = CGSizeMake( hOffset, vOffset);
			tl = CGSizeMake(-1.0f, vOffset);
			bl = CGSizeMake(-1.0f,-1.0f);
			br = CGSizeMake( hOffset,-1.0f);
			break;
		case 8: //kCAGravityBottomRight
			tr = CGSizeMake( 1.0f, vOffset);
			tl = CGSizeMake(-hOffset, vOffset);
			bl = CGSizeMake(-hOffset,-1.0f);
			br = CGSizeMake( 1.0f,-1.0f);
			break;
		case 10: //kCAGravityResizeAspect
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
			break;
		case 11: //kCAGravityResizeAspectFill
			if (lAspect > vAspect) {	// Layer is wider aspect than video - Expand vertically
				tr = CGSizeMake( 1.0f, vRatio/hRatio);
				tl = CGSizeMake(-1.0f, vRatio/hRatio);
				bl = CGSizeMake(-1.0f,-vRatio/hRatio);
				br = CGSizeMake( 1.0f,-vRatio/hRatio);
			} else {					// Layer is narrow aspect than video - Expand horizontally
				tr = CGSizeMake( hRatio/vRatio, 1.0f);
				tl = CGSizeMake(-hRatio/vRatio, 1.0f);
				bl = CGSizeMake(-hRatio/vRatio,-1.0f);
				br = CGSizeMake( hRatio/vRatio,-1.0f);
			}
			break;
		case 9:	//kCAGravityResize
		default:
			// The default value is kCAGravityResize
			tr = CGSizeMake( 1.0f, 1.0f);
			tl = CGSizeMake(-1.0f, 1.0f);
			bl = CGSizeMake(-1.0f,-1.0f);
			br = CGSizeMake( 1.0f,-1.0f);
			break;
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
		CVPixelBufferRetain(pixelbuffer);
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
	//NSLog(@"setStream:");
	
	[lock lock];
	
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
	
	// Try to update CAOpenGLLayer
	[self setNeedsDisplay];
	
	[lock unlock];
}

@end
