//
//  GameViewController.hh
//  Wave
//
//  Created by Leon Rinkel on 05.09.23.
//

#import <Cocoa/Cocoa.h>

#import <Metal/Metal.h>
#import <MetalKit/MetalKit.h>

#import <AVFAudio/AVFAudio.h>

// Our macOS view controller.
@interface AppViewController : NSViewController<NSWindowDelegate>

@property (nonatomic, strong) NSURL *file;
@property (nonatomic, strong) AVAudioPlayer *player;

@end

@interface AppViewController () <MTKViewDelegate>

@property (nonatomic, readonly) MTKView *mtkView;
@property (nonatomic, strong) id <MTLDevice> device;
@property (nonatomic, strong) id <MTLCommandQueue> commandQueue;

@end
