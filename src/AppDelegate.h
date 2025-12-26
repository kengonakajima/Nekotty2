#import <Cocoa/Cocoa.h>
#import <ghostty.h>

@interface AppDelegate : NSObject <NSApplicationDelegate>

@property (strong, nonatomic) NSWindow *window;

- (void)tick;
- (void)handleWakeup;
- (void)updatePwd:(NSString *)pwd forSurface:(ghostty_surface_t)surface;

@end
