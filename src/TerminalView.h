#import <Cocoa/Cocoa.h>
#import <ghostty.h>

@interface TerminalView : NSView

@property (nonatomic, assign) ghostty_surface_t surface;

- (instancetype)initWithApp:(ghostty_app_t)app frame:(NSRect)frame;

@end
