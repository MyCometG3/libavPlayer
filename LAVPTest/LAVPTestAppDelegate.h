//
//  LAVPTestAppDelegate.h
//  LAVPTest
//
//  Created by Takashi Mochizuki on 11/06/19.
//  Copyright 2011 MyCometG3. All rights reserved.
//

#import <Cocoa/Cocoa.h>
#import <libavPlayer/libavPlayer.h>

@interface LAVPTestAppDelegate : NSObject <NSApplicationDelegate> {
    NSWindow *window;
	IBOutlet LAVPView *lavpView;
	LAVPStream *stream;
	
	NSWindow *layerwindow;
	LAVPLayer *layer;
	LAVPStream *layerstream;
}

@property (assign) IBOutlet NSWindow *window;
@property (assign) IBOutlet NSWindow *layerwindow;


- (IBAction) togglePlay:(id)sender;

- (IBAction) togglePlayLayer:(id)sender;

@end
