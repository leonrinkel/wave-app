//
//  AppDelegate.mm
//  Wave
//
//  Created by Leon Rinkel on 05.09.23.
//

#import "AppDelegate.hh"

#import "AppViewController.hh"

@interface AppDelegate ()

@end

@implementation AppDelegate

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

- (instancetype)init {
    if (self = [super init]) {
        NSViewController *rootViewController = [[AppViewController alloc] initWithNibName:nil bundle:nil];
        self.window = [[NSWindow alloc] initWithContentRect:NSZeroRect styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable | NSWindowStyleMaskMiniaturizable backing:NSBackingStoreBuffered defer:NO];
        self.window.contentViewController = rootViewController;
        [self.window center];
        [self.window makeKeyAndOrderFront:self];
    }

    return self;
}

@end
