//
//  LAVPTestAppDelegate.h
//  LAVPTest
//
//  Created by Takashi Mochizuki on 11/06/19.
//  Copyright 2011 MyCometG3. All rights reserved.
//

#import <Cocoa/Cocoa.h>

@interface LAVPTestAppDelegate : NSObject <NSApplicationDelegate> {
	LAVPStream *viewstream;
	double_t viewPos;
	NSString *viewTitle;
	
	LAVPLayer *layer;
	LAVPStream *layerstream;
	double_t layerPos;
	NSString *layerTitle;
	
	NSTimer *timer;
	double_t prevRate;
	double_t layerPrev;
	double_t viewPrev;
}

@property (unsafe_unretained) IBOutlet NSWindow *viewwindow;
@property (unsafe_unretained) IBOutlet LAVPView *view;
@property (unsafe_unretained) IBOutlet NSWindow *layerwindow;
@property (unsafe_unretained) IBOutlet NSView *layerView;

- (void) loadMovieAtURL:(NSURL *)url;

- (IBAction) togglePlay:(id)sender;
- (IBAction) rewindStream:(id)sender;
- (IBAction) updatePosition:(id)sender;

@end
