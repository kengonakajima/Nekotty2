#import <Cocoa/Cocoa.h>
#import "AppDelegate.h"
#import <ghostty.h>

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        // Initialize libghostty
        if (ghostty_init(argc, (char **)argv) != GHOSTTY_SUCCESS) {
            NSLog(@"ghostty_init failed");
            return 1;
        }
        NSLog(@"ghostty_init succeeded");

        NSApplication *app = [NSApplication sharedApplication];
        AppDelegate *delegate = [[AppDelegate alloc] init];
        [app setDelegate:delegate];
        [app setActivationPolicy:NSApplicationActivationPolicyRegular];
        [app activateIgnoringOtherApps:YES];
        [app run];
    }
    return 0;
}
