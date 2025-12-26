#import "TerminalView.h"
#import <QuartzCore/QuartzCore.h>

@implementation TerminalView {
    NSString *_markedText;
    NSRange _markedRange;
    NSRange _selectedRange;
}

@synthesize lastCapturedText = _lastCapturedText;
@synthesize cachedThumbnail = _cachedThumbnail;
@synthesize needsThumbnailUpdate = _needsThumbnailUpdate;

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

- (NSString *)projectName {
    if (!self.pwd || self.pwd.length == 0) {
        return @"(unknown)";
    }

    // Expand ~ to home directory
    NSString *expanded = [self.pwd stringByExpandingTildeInPath];
    NSString *home = NSHomeDirectory();

    // Check if path is under home directory
    if ([expanded hasPrefix:home]) {
        NSString *relative = [expanded substringFromIndex:home.length];
        // Remove leading /
        if ([relative hasPrefix:@"/"]) {
            relative = [relative substringFromIndex:1];
        }
        // Get first path component as project name
        NSArray *components = [relative pathComponents];
        if (components.count > 0) {
            return components[0];
        }
    }

    // Not under home, use first path component after root
    NSArray *components = [expanded pathComponents];
    if (components.count > 1) {
        return components[1];
    }

    return @"(root)";
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
        self.needsThumbnailUpdate = YES;
    }
}

// Keyboard input
- (void)keyDown:(NSEvent *)event {
    if (!self.surface) return;
    [self interpretKeyEvents:@[event]];
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

#pragma mark - NSTextInputClient

- (void)insertText:(id)string replacementRange:(NSRange)replacementRange {
    if (!self.surface) return;

    NSString *text = [string isKindOfClass:[NSAttributedString class]]
        ? [(NSAttributedString *)string string]
        : (NSString *)string;

    // Always clear preedit state before sending text
    ghostty_surface_preedit(self.surface, NULL, 0);

    // Clear marked text state
    _markedText = nil;
    _markedRange = NSMakeRange(NSNotFound, 0);

    // Send text via key event (like Ghostty does)
    NSEvent *event = [NSApp currentEvent];
    if (event && text.length > 0) {
        ghostty_input_key_s key = {0};
        key.action = GHOSTTY_ACTION_PRESS;
        key.mods = [self modsFromEvent:event];
        key.keycode = [event keyCode];
        key.composing = NO;

        const char *utf8 = [text UTF8String];
        if (utf8 && (uint8_t)utf8[0] >= 0x20) {
            key.text = utf8;
        }
        ghostty_surface_key(self.surface, key);
    }
}

- (void)setMarkedText:(id)string selectedRange:(NSRange)selectedRange replacementRange:(NSRange)replacementRange {
    NSString *text = [string isKindOfClass:[NSAttributedString class]]
        ? [(NSAttributedString *)string string]
        : (NSString *)string;

    _markedText = text;
    _selectedRange = selectedRange;
    _markedRange = NSMakeRange(0, text.length);

    // Send preedit to terminal
    if (self.surface && text.length > 0) {
        const char *utf8 = [text UTF8String];
        if (utf8) {
            ghostty_surface_preedit(self.surface, utf8, strlen(utf8));
        }
    }
}

- (void)unmarkText {
    if (_markedText.length > 0) {
        _markedText = nil;
        _markedRange = NSMakeRange(NSNotFound, 0);
        if (self.surface) {
            ghostty_surface_preedit(self.surface, NULL, 0);
        }
    }
}

- (NSRange)selectedRange {
    return _selectedRange;
}

- (NSRange)markedRange {
    return _markedRange;
}

- (BOOL)hasMarkedText {
    return _markedText.length > 0;
}

- (NSAttributedString *)attributedSubstringForProposedRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    return nil;
}

- (NSArray<NSAttributedStringKey> *)validAttributesForMarkedText {
    return @[];
}

- (NSRect)firstRectForCharacterRange:(NSRange)range actualRange:(NSRangePointer)actualRange {
    // Return cursor position for IME candidate window
    NSRect rect = NSMakeRect(0, 0, 0, 20);
    if (self.window) {
        rect = [self convertRect:rect toView:nil];
        rect = [self.window convertRectToScreen:rect];
    }
    return rect;
}

- (NSUInteger)characterIndexForPoint:(NSPoint)point {
    return NSNotFound;
}

- (void)doCommandBySelector:(SEL)selector {
    // Handle special keys (Enter, Delete, arrows, etc.)
    if (!self.surface) return;

    NSEvent *event = [NSApp currentEvent];
    if (event && event.type == NSEventTypeKeyDown) {
        ghostty_input_key_s key = {0};
        key.action = GHOSTTY_ACTION_PRESS;
        key.mods = [self modsFromEvent:event];
        key.keycode = [event keyCode];
        key.composing = NO;
        key.text = NULL;

        ghostty_surface_key(self.surface, key);
    }
}

- (NSString *)lastLinesText:(int)lineCount maxChars:(int)maxChars {
    if (!self.surface) return @"";

    // Get terminal grid size
    ghostty_surface_size_s size = ghostty_surface_size(self.surface);
    if (size.rows == 0 || size.columns == 0) return @"";

    // Calculate selection for last N lines
    int startRow = (size.rows > lineCount) ? (size.rows - lineCount) : 0;
    int endCol = (size.columns > maxChars) ? maxChars : size.columns;

    ghostty_selection_s selection = {0};
    selection.top_left.x = 0;
    selection.top_left.y = startRow;
    selection.bottom_right.x = endCol;
    selection.bottom_right.y = size.rows;
    selection.rectangle = true;

    ghostty_text_s text = {0};
    if (!ghostty_surface_read_text(self.surface, selection, &text)) {
        return @"";
    }

    NSString *result = @"";
    if (text.text && text.text_len > 0) {
        result = [[NSString alloc] initWithBytes:text.text
                                          length:text.text_len
                                        encoding:NSUTF8StringEncoding];
        if (!result) result = @"";
    }

    ghostty_surface_free_text(self.surface, &text);
    return result;
}

- (NSString *)firstLinesText:(int)lineCount maxChars:(int)maxChars {
    if (!self.surface) return @"";

    // Get terminal grid size
    ghostty_surface_size_s size = ghostty_surface_size(self.surface);
    if (size.rows == 0 || size.columns == 0) return @"";

    // Calculate selection for first N lines
    int endRow = (lineCount < size.rows) ? lineCount : size.rows;
    int endCol = (size.columns > maxChars) ? maxChars : size.columns;

    ghostty_selection_s selection = {0};
    selection.top_left.x = 0;
    selection.top_left.y = 0;
    selection.bottom_right.x = endCol;
    selection.bottom_right.y = endRow;
    selection.rectangle = true;

    ghostty_text_s text = {0};
    if (!ghostty_surface_read_text(self.surface, selection, &text)) {
        return @"";
    }

    NSString *result = @"";
    if (text.text && text.text_len > 0) {
        result = [[NSString alloc] initWithBytes:text.text
                                          length:text.text_len
                                        encoding:NSUTF8StringEncoding];
        if (!result) result = @"";
    }

    ghostty_surface_free_text(self.surface, &text);
    return result;
}

@end
