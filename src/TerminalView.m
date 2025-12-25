#import "TerminalView.h"
#import <QuartzCore/QuartzCore.h>

@implementation TerminalView

- (instancetype)initWithApp:(ghostty_app_t)app frame:(NSRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        self.wantsLayer = YES;
        self.layerContentsRedrawPolicy = NSViewLayerContentsRedrawDuringViewResize;

        // Create surface config
        ghostty_surface_config_s config = ghostty_surface_config_new();
        config.platform_tag = GHOSTTY_PLATFORM_MACOS;
        config.platform.macos.nsview = (__bridge void *)self;
        config.scale_factor = [[NSScreen mainScreen] backingScaleFactor];
        config.font_size = 0;  // Use default

        // Create surface
        self.surface = ghostty_surface_new(app, &config);
        if (!self.surface) {
            NSLog(@"Failed to create ghostty surface");
            return nil;
        }
        NSLog(@"Created ghostty surface: %p", self.surface);
    }
    return self;
}

- (void)dealloc {
    if (self.surface) {
        ghostty_surface_free(self.surface);
    }
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)canBecomeKeyView {
    return YES;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (self.window && self.surface) {
        ghostty_surface_set_focus(self.surface, YES);
        [self updateSize];
    }
}

- (void)viewDidMoveToSuperview {
    [super viewDidMoveToSuperview];
    [self updateSize];
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updateSize];
}

- (void)resizeSubviewsWithOldSize:(NSSize)oldSize {
    [super resizeSubviewsWithOldSize:oldSize];
    [self updateSize];
}

- (void)updateSize {
    if (!self.surface) return;
    NSSize size = self.bounds.size;
    if (size.width <= 0 || size.height <= 0) return;

    double scale = self.window ? self.window.backingScaleFactor : [[NSScreen mainScreen] backingScaleFactor];
    uint32_t width = (uint32_t)(size.width * scale);
    uint32_t height = (uint32_t)(size.height * scale);
    NSLog(@"updateSize: bounds=%.0fx%.0f scale=%.1f pixels=%ux%u", size.width, size.height, scale, width, height);
    ghostty_surface_set_size(self.surface, width, height);
}

- (void)drawRect:(NSRect)dirtyRect {
    if (self.surface) {
        ghostty_surface_draw(self.surface);
    }
}

// Keyboard input
- (void)keyDown:(NSEvent *)event {
    if (!self.surface) return;

    ghostty_input_key_s key = {0};
    key.action = GHOSTTY_ACTION_PRESS;
    key.mods = [self modsFromEvent:event];
    key.keycode = [event keyCode];
    key.text = [[event characters] UTF8String];

    if (!ghostty_surface_key(self.surface, key)) {
        [super keyDown:event];
    }
}

- (void)keyUp:(NSEvent *)event {
    if (!self.surface) return;

    ghostty_input_key_s key = {0};
    key.action = GHOSTTY_ACTION_RELEASE;
    key.mods = [self modsFromEvent:event];
    key.keycode = [event keyCode];

    ghostty_surface_key(self.surface, key);
}

- (ghostty_input_mods_e)modsFromEvent:(NSEvent *)event {
    ghostty_input_mods_e mods = GHOSTTY_MODS_NONE;
    NSEventModifierFlags flags = [event modifierFlags];

    if (flags & NSEventModifierFlagShift) mods |= GHOSTTY_MODS_SHIFT;
    if (flags & NSEventModifierFlagControl) mods |= GHOSTTY_MODS_CTRL;
    if (flags & NSEventModifierFlagOption) mods |= GHOSTTY_MODS_ALT;
    if (flags & NSEventModifierFlagCommand) mods |= GHOSTTY_MODS_SUPER;
    if (flags & NSEventModifierFlagCapsLock) mods |= GHOSTTY_MODS_CAPS;

    return mods;
}

@end
