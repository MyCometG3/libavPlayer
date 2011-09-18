//
//  LAVPTestAppDelegate.h
//  LAVPTest
//
//  Created by Takashi Mochizuki on 11/06/19.
//  Copyright 2011 MyCometG3. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface LAVPTestAppDelegate : NSObject <NSApplicationDelegate> {
	IBOutlet NSWindow *viewwindow;
	IBOutlet LAVPView *view;
	LAVPStream *viewstream;
	double_t viewPos;
	
	IBOutlet NSWindow *layerwindow;
	IBOutlet NSView *layerView;
	LAVPLayer *layer;
	LAVPStream *layerstream;
	double_t layerPos;
	
	NSTimer *timer;
}

@property (assign) IBOutlet NSWindow *viewwindow;
@property (assign) IBOutlet NSWindow *layerwindow;

- (void) loadMovieAtURL:(NSURL *)url;

- (IBAction) togglePlayView:(id)sender;
- (IBAction) togglePlayLayer:(id)sender;
- (IBAction) rewindStream:(id)sender;
- (IBAction) updatePosition:(id)sender;

@end
