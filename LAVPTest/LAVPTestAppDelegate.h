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
	NSString *viewTitle;
	
	IBOutlet NSWindow *layerwindow;
	IBOutlet NSView *layerView;
	LAVPLayer *layer;
	LAVPStream *layerstream;
	double_t layerPos;
	NSString *layerTitle;
	
	NSTimer *timer;
}

@property (assign) IBOutlet NSWindow *viewwindow;
@property (assign) IBOutlet NSWindow *layerwindow;

- (void) loadMovieAtURL:(NSURL *)url;

- (IBAction) togglePlay:(id)sender;
- (IBAction) rewindStream:(id)sender;
- (IBAction) updatePosition:(id)sender;

@end
