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
}

- (void) loadMovieAtURL:(NSURL *)url
{
#if 1
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
	
//	[view setNeedsDisplay:YES];
//	[stream gotoBeggining];
#endif
	
#if 1
	if (layerstream) {
		[layerstream stop];
		[layer setStream:nil];
		[layerstream release];
		layerstream = nil;
	}
	
	// LAVPLayer test
	layerstream =  [[LAVPStream streamWithURL:url error:nil] retain];
	
	//
	[[layerwindow contentView] setWantsLayer:YES];
	CALayer *contentLayer = [[layerwindow contentView] layer];
	
	//
	CALayer *rootLayer;
#if 1
	rootLayer = contentLayer;
#else
	rootLayer = [CALayer new];
	rootLayer.bounds = contentLayer.bounds;
	rootLayer.frame = contentLayer.frame;
	rootLayer.position = CGPointMake(contentLayer.bounds.size.width/2.0, contentLayer.bounds.size.height/2.0);
	rootLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
	
	contentLayer.layoutManager = [CAConstraintLayoutManager layoutManager];
	contentLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
	[contentLayer addSublayer:rootLayer];
#endif
	
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
	
//	[layer setNeedsDisplay];
//	[layerstream gotoBeggining];
#endif
}

- (BOOL) applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender
{
	return YES;
}

- (void) windowWillClose:(NSNotification *)notification
{
	NSWindow *obj = [notification object];
	if (obj == layerwindow) {
		NSLog(@"layerwindow closed.");
		[layerstream stop];
		[layer setStream:nil];
		[layerstream release];
		layerstream = nil;
	}
	if (obj == viewwindow) {
		NSLog(@"viewwindow closed.");
		[viewstream stop];
		[view setStream:nil];
		[viewstream release];
		viewstream = nil;
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

@end

