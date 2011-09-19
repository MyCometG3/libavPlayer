//
//  LAVPTestAppDelegate.m
//  LAVPTest
//
//  Created by Takashi Mochizuki on 11/06/19.
//  Copyright 2011 MyCometG3. All rights reserved.
//

#import "LAVPTestAppDelegate.h"

@implementation LAVPTestAppDelegate

@synthesize viewwindow;
@synthesize layerwindow;

- (void)startTimer
{
	timer = [NSTimer scheduledTimerWithTimeInterval:0.1 target:self selector:@selector(updatePos:) userInfo:nil repeats:YES];
}

- (void)stopTimer
{
	if (timer) {
		[timer invalidate];
		timer = nil;
	}
}

- (void)updatePos:(NSTimer*)theTimer
{
	if (layerwindow) {
		[self setValue:[NSNumber numberWithDouble:layerstream.position ] forKey:@"layerPos"];
	}
	if (viewwindow) {
		[self setValue:[NSNumber numberWithDouble:viewstream.position ] forKey:@"viewPos"];
	}
}

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
	// Restore prev movie (on start up)
	NSURL *url = [[NSUserDefaults standardUserDefaults] URLForKey:@"url"];
	NSURL *urlDefault = [[NSBundle mainBundle] URLForResource:@"ColorBars" withExtension:@"mov"];
	
	if (url) {
		NSError *error = NULL;
		NSFileWrapper *file = [[[NSFileWrapper alloc] initWithURL:url 
														 options:NSFileWrapperReadingImmediate 
														   error:&error] autorelease];
		if ( file ) {
			[self loadMovieAtURL:url];
			return;
		}
	}
	[self loadMovieAtURL:urlDefault];
	
	timer = nil;
}

- (void) loadMovieAtURL:(NSURL *)url
{
	if (layerstream || viewstream) {
		[self stopTimer];
	}
#if 1
	if (viewwindow) {
		if (viewstream) {
			[viewstream stop];
			[view setStream:nil];
			[viewstream release];
			viewstream = nil;
		}
		
		// LAVPView test
		viewstream = [[LAVPStream streamWithURL:url error:nil] retain];
		
		[view setExpandToFit:YES];
		
		//
		[view setStream:viewstream];
	}
#endif
	
#if 1
	if (layerwindow) {
		if (layerstream) {
			[layerstream stop];
			[layer setStream:nil];
			[layerstream release];
			layerstream = nil;
		}
		
		// LAVPLayer test
		layerstream =  [[LAVPStream streamWithURL:url error:nil] retain];
		
		//
		[layerView setWantsLayer:YES];
		CALayer *rootLayer = [layerView layer];
		rootLayer.needsDisplayOnBoundsChange = YES;
		
		//
		layer = [LAVPLayer layer];
		
	//	layer.contentsGravity = kCAGravityBottomRight;
	//	layer.contentsGravity = kCAGravityBottomLeft;
	//	layer.contentsGravity = kCAGravityTopRight;
	//	layer.contentsGravity = kCAGravityTopLeft;
	//	layer.contentsGravity = kCAGravityRight;
	//	layer.contentsGravity = kCAGravityLeft;
	//	layer.contentsGravity = kCAGravityBottom;
	//	layer.contentsGravity = kCAGravityTop;
	//	layer.contentsGravity = kCAGravityCenter;
	//	layer.contentsGravity = kCAGravityResize;
		layer.contentsGravity = kCAGravityResizeAspect;
	//	layer.contentsGravity = kCAGravityResizeAspectFill;
		
		layer.frame = rootLayer.frame;
	//	layer.bounds = rootLayer.bounds;
	//	layer.position = rootLayer.position;
		layer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
		layer.backgroundColor = CGColorGetConstantColor(kCGColorBlack);
		
		//
		[layer setStream:layerstream];
		[rootLayer addSublayer:layer];

	}
#endif
	if (layerstream || viewstream) {
		[self startTimer];
	}
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	return YES;
}

- (void) windowWillClose:(NSNotification *)notification
{
	//NSLog(@"LAVPTest: -windowWillClose:");
	NSWindow *obj = [notification object];
	if (obj == layerwindow) {
		NSLog(@"layerwindow closing...");
		[layerstream stop];
		[layer setStream:nil];
		[layerstream release];
		layerstream = nil;
		layerwindow = nil;
		NSLog(@"layerwindow closed.");
	}
	if (obj == viewwindow) {
		NSLog(@"viewwindow closing...");
		[viewstream stop];
		[view setStream:nil];
		[viewstream release];
		viewstream = nil;
		viewwindow = nil;
		NSLog(@"viewwindow closed.");
	}
}

- (IBAction) togglePlayView:(id)sender
{
	if ([viewstream rate]) {
		[viewstream stop];
	} else {
		QTTime currentTime = [viewstream currentTime];
		QTTime duration = [viewstream duration];
		if (currentTime.timeValue + 1e6/30 >= duration.timeValue) {
			[viewstream gotoBeggining];
		}
		
		// test code for playRate support
		BOOL shiftKey = [NSEvent modifierFlags] & NSShiftKeyMask ? TRUE : FALSE;
		if (shiftKey) {
			[viewstream setRate:1.5];
		} else {
			[viewstream setRate:1.0];
		}
	}
//	[view setNeedsDisplay:YES];
}

- (IBAction) togglePlayLayer:(id)sender
{
	if ([layerstream rate]) {
		[layerstream stop];
	} else {
		QTTime currentTime = [layerstream currentTime];
		QTTime duration = [layerstream duration];
		if (currentTime.timeValue + 1e6/30 >= duration.timeValue) {
			[layerstream gotoBeggining];
		}
		
		// test code for playRate support
		BOOL shiftKey = [NSEvent modifierFlags] & NSShiftKeyMask ? TRUE : FALSE;
		if (shiftKey) {
			[layerstream setRate:1.5];
		} else {
			[layerstream setRate:1.0];
		}
	}
//	[layer setNeedsDisplay];
}

- (IBAction) openDocument:(id)sender
{
	// configure open sheet
	NSOpenPanel *openPanel = [NSOpenPanel openPanel];
	
	// build completion block
	void (^movieOpenPanelHandler)(NSInteger) = ^(NSInteger result)
	{
		if (result == NSFileHandlingPanelOKButton) {
			// Load new movie
			NSURL *newURL = [openPanel URL];
			[openPanel close];
			
			[[NSUserDefaults standardUserDefaults] setURL:newURL forKey:@"url"];
			[[NSUserDefaults standardUserDefaults] synchronize];
			
			[self loadMovieAtURL:newURL];
		}
	};
	
	// show sheet
	[openPanel beginSheetModalForWindow:[NSApp mainWindow] completionHandler:movieOpenPanelHandler];
}

- (IBAction) rewindStream:(id)sender
{
	NSButton *button = (NSButton*) sender;
	if ([button window] == layerwindow) {
		[layerstream gotoBeggining];
	}
	if ([button window] == viewwindow) {
		[viewstream gotoBeggining];
	}
}

- (IBAction) updatePosition:(id)sender
{
	NSScroller *pos = (NSScroller*) sender;
	if ([pos window] == layerwindow && !layerstream.busy) {
		[layerstream setPosition:[sender doubleValue]];
	}
	if ([pos window] == viewwindow && !viewstream.busy) {
		[viewstream setPosition:[sender doubleValue]];
	}
}

@end

