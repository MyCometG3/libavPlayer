//
//  LAVPTestAppDelegate.m
//  LAVPTest
//
//  Created by Takashi Mochizuki on 11/06/19.
//  Copyright 2011 MyCometG3. All rights reserved.
//

#import "LAVPTestAppDelegate.h"

@implementation LAVPTestAppDelegate

@synthesize window;
@synthesize layerwindow;

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
//	NSURL *url = [[NSBundle mainBundle] URLForResource:@"test" withExtension:@"mp4"];
	NSURL *url = [[NSBundle mainBundle] URLForResource:@"test2" withExtension:@"mp4"];
//	NSURL *url = [[NSBundle mainBundle] URLForResource:@"test3" withExtension:@"mp4"];
	
#if 1
	
	// LAVPLayer test
	
	layerstream =  [[LAVPStream streamWithURL:url error:nil] retain];
	
	//while ( NSEqualSizes([layerstream frameSize], NSZeroSize) ) {
	//	[NSThread sleepForTimeInterval:0.01];
	//}
	//NSLog(@"size = %@", NSStringFromSize([layerstream frameSize]));
	
	//
	[[layerwindow contentView] setWantsLayer:YES];
	CALayer *contentLayer = [[layerwindow contentView] layer];
	
	CALayer *rootLayer;
//	rootLayer = [CALayer new];
//	rootLayer.bounds = contentLayer.bounds;
//	rootLayer.frame = contentLayer.frame;
//	rootLayer.position = CGPointMake(contentLayer.bounds.size.width/2.0, contentLayer.bounds.size.height/2.0);
//	rootLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
//	
//	contentLayer.layoutManager = [CAConstraintLayoutManager layoutManager];
//	contentLayer.autoresizingMask = kCALayerWidthSizable | kCALayerHeightSizable;
//	[contentLayer addSublayer:rootLayer];
	rootLayer = contentLayer;
	
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
//	layer.asynchronous = YES;
	
	[layer setStream:layerstream];
	[rootLayer addSublayer:layer];
	
	//
	[layer performSelector:@selector(setNeedsDisplay) withObject:self afterDelay:0.5];
//	[layer setNeedsDisplay];
//	[layerstream gotoBeggining];
//	[layerstream stop];
#endif

#if 1
	// LAVPView test
	
	stream = [[LAVPStream streamWithURL:url error:nil] retain];
	
	//while ( NSEqualSizes([stream frameSize], NSZeroSize) ) {
	//	[NSThread sleepForTimeInterval:0.01];
	//}
	//NSLog(@"size = %@", NSStringFromSize([stream frameSize]));
	
	[lavpView setStream:stream];
	[lavpView setExpandToFit:YES];
	
	//
	[lavpView setNeedsDisplay:YES];
//	[stream gotoBeggining];
//	[stream stop];
#endif

}

- (IBAction) togglePlay:(id)sender
{
	if ([stream rate]) {
		[stream stop];
	} else {
		[stream play];
	}
}

- (IBAction) togglePlayLayer:(id)sender
{
	if ([layerstream rate]) {
		[layerstream stop];
	} else {
		[layerstream play];
	}
	[layer setNeedsDisplay];
}

@end

