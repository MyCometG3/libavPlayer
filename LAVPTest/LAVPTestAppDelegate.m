//
//  LAVPTestAppDelegate.m
//  LAVPTest
//
//  Created by Takashi Mochizuki on 11/06/19.
//  Copyright 2011 MyCometG3. All rights reserved.
//

#import "LAVPTestAppDelegate.h"

NSString* formatTime(QTTime qttime)
{
	SInt32 i = qttime.timeValue / qttime.timeScale;
	SInt32 d = i / (24*60*60);
	SInt32 h = (i - d * (24*60*60)) / (60*60);
	SInt32 m = (i - d * (24*60*60) - h * (60*60)) / 60;
	SInt32 s = (i - d * (24*60*60) - h * (60*60) - m * 60);
	SInt32 f = (qttime.timeValue % qttime.timeScale) * 1000 / qttime.timeScale;	// Just micro second
	return [NSString stringWithFormat:@"%02d:%02d:%02d:%03d", h, m, s, f];
}

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
		double_t pos = layerstream.position;
		[self setValue:[NSNumber numberWithDouble:pos] forKey:@"layerPos"];
		NSString *timeStr = formatTime([layerstream currentTime]);
		[self setValue:[NSString stringWithFormat:@"Layer Window : %@ (%.3f)", timeStr, pos] 
				forKey:@"layerTitle"];
	}
	if (viewwindow) {
		double_t pos = viewstream.position;
		[self setValue:[NSNumber numberWithDouble:pos] forKey:@"viewPos"];
		NSString *timeStr = formatTime([viewstream currentTime]);
		[self setValue:[NSString stringWithFormat:@"View Window : %@ (%.3f)", timeStr, pos] 
				forKey:@"viewTitle"];
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
	layerPrev = -1;
	viewPrev = -1;
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

- (IBAction) togglePlay:(id)sender
{
	LAVPStream *theStream = nil;
	
	NSButton *button = (NSButton*) sender;
	if ([button window] == layerwindow) {
		theStream = layerstream;
	}
	if ([button window] == viewwindow) {
		theStream = viewstream;
	}
	
	if ([theStream rate]) {
		[theStream stop];
	} else {
		QTTime currentTime = [theStream currentTime];
		QTTime duration = [theStream duration];
		if (currentTime.timeValue + 1e6/30 >= duration.timeValue) {
			[theStream gotoBeggining];
		}
		
		// test code for playRate support
		BOOL shiftKey = [NSEvent modifierFlags] & NSShiftKeyMask ? TRUE : FALSE;
		if (shiftKey) {
			[theStream setRate:1.5];
		} else {
			[theStream setRate:1.0];
		}
	}
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
	NSSlider *pos = (NSSlider*) sender;
	double_t newPos = [pos doubleValue];
	
	if ([pos window] == layerwindow && !layerstream.busy) {
		if ([layerstream rate]) {
			prevRate = [layerstream rate];
			[layerstream stop];
			layerstream.strictSeek = NO;
		}
		if (newPos != layerPrev) {
			[layerstream setPosition:newPos];
			layerPrev = newPos;
		}
	}
	if ([pos window] == viewwindow && !viewstream.busy) {
		if ([viewstream rate]) {
			prevRate = [viewstream rate];
			[viewstream stop];
			viewstream.strictSeek = NO;
		}
		if (newPos != viewPrev) {
			[viewstream setPosition:newPos];
			viewPrev = newPos;
		}
	}
	
    SEL trackingEndedSelector = @selector(finishUpdatePosition:);
    [NSObject cancelPreviousPerformRequestsWithTarget:self
											 selector:trackingEndedSelector object:sender];
    [self performSelector:trackingEndedSelector withObject:sender afterDelay:0.0];
}

- (void) finishUpdatePosition:(id)sender
{
	NSSlider *pos = (NSSlider*) sender;
	if ([pos window] == layerwindow && !layerstream.busy) {
		[layerstream setRate:prevRate];
		layerstream.strictSeek = YES;
	}
	if ([pos window] == viewwindow && !viewstream.busy) {
		[viewstream setRate:prevRate];
		viewstream.strictSeek = YES;
	}
	prevRate = 0;
	layerPrev = -1;
	viewPrev = -1;
}

@end

