#import "AppDelegate.h"
#import "TerminalView.h"
#import <ghostty.h>

// Runtime callbacks
static void wakeup_cb(void *userdata) {
    dispatch_async(dispatch_get_main_queue(), ^{
        AppDelegate *delegate = (__bridge AppDelegate *)userdata;
        [delegate tick];
    });
}

static bool action_cb(ghostty_app_t app, ghostty_target_s target, ghostty_action_s action) {
    NSLog(@"action_cb: tag=%d", action.tag);
    return false;
}

static void read_clipboard_cb(void *userdata, ghostty_clipboard_e loc, void *state) {
    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *str = [pb stringForType:NSPasteboardTypeString];
    ghostty_surface_complete_clipboard_request(state, str ? [str UTF8String] : NULL, NULL, false);
}

static void confirm_read_clipboard_cb(void *userdata, const char *str, void *state,
                                       ghostty_clipboard_request_e request) {
    // Auto-confirm for now
    ghostty_surface_complete_clipboard_request(state, str, NULL, false);
}

static void write_clipboard_cb(void *userdata, ghostty_clipboard_e loc,
                                const ghostty_clipboard_content_s *content,
                                size_t len, bool confirm) {
    if (len > 0 && content[0].data) {
        NSPasteboard *pb = [NSPasteboard generalPasteboard];
        [pb clearContents];
        [pb setString:[NSString stringWithUTF8String:content[0].data]
              forType:NSPasteboardTypeString];
    }
}

static void close_surface_cb(void *userdata, bool processAlive) {
    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSApplication sharedApplication] terminate:nil];
    });
}

@implementation AppDelegate {
    ghostty_app_t _app;
    ghostty_config_t _config;
    NSSplitView *_splitView;
    NSView *_leftPane;       // Tree view placeholder
    TerminalView *_terminalView;
    NSTimer *_tickTimer;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    // Create config
    _config = ghostty_config_new();
    ghostty_config_load_default_files(_config);
    ghostty_config_finalize(_config);
    NSLog(@"Config created: %p", _config);

    // Create runtime config with callbacks
    ghostty_runtime_config_s runtime_cfg = {0};
    runtime_cfg.userdata = (__bridge void *)self;
    runtime_cfg.supports_selection_clipboard = false;
    runtime_cfg.wakeup_cb = wakeup_cb;
    runtime_cfg.action_cb = action_cb;
    runtime_cfg.read_clipboard_cb = read_clipboard_cb;
    runtime_cfg.confirm_read_clipboard_cb = confirm_read_clipboard_cb;
    runtime_cfg.write_clipboard_cb = write_clipboard_cb;
    runtime_cfg.close_surface_cb = close_surface_cb;

    // Create app
    _app = ghostty_app_new(&runtime_cfg, _config);
    if (!_app) {
        NSLog(@"Failed to create ghostty app");
        return;
    }
    NSLog(@"App created: %p", _app);

    // Create window
    NSRect frame = NSMakeRect(100, 100, 1200, 800);
    NSWindowStyleMask style = NSWindowStyleMaskTitled
                            | NSWindowStyleMaskClosable
                            | NSWindowStyleMaskMiniaturizable
                            | NSWindowStyleMaskResizable;

    self.window = [[NSWindow alloc] initWithContentRect:frame
                                              styleMask:style
                                                backing:NSBackingStoreBuffered
                                                  defer:NO];
    [self.window setTitle:@"Nekotty"];
    [self.window setBackgroundColor:[NSColor blackColor]];

    // Create split view
    NSRect contentBounds = [[self.window contentView] bounds];
    _splitView = [[NSSplitView alloc] initWithFrame:contentBounds];
    [_splitView setVertical:YES];
    [_splitView setDividerStyle:NSSplitViewDividerStyleThin];
    [_splitView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    // Create left pane (tree view placeholder)
    CGFloat leftWidth = 300;
    NSRect leftFrame = NSMakeRect(0, 0, leftWidth, contentBounds.size.height);
    _leftPane = [[NSView alloc] initWithFrame:leftFrame];
    [_leftPane setWantsLayer:YES];
    [_leftPane.layer setBackgroundColor:[[NSColor colorWithWhite:0.15 alpha:1.0] CGColor]];

    // Create terminal view (right pane)
    NSRect rightFrame = NSMakeRect(0, 0, contentBounds.size.width - leftWidth, contentBounds.size.height);
    _terminalView = [[TerminalView alloc] initWithApp:_app frame:rightFrame];
    if (!_terminalView) {
        NSLog(@"Failed to create terminal view");
        return;
    }
    [_terminalView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    // Add subviews to split view
    [_splitView addSubview:_leftPane];
    [_splitView addSubview:_terminalView];

    [[self.window contentView] addSubview:_splitView];

    // Set divider position after layout is complete
    CGFloat savedLeftWidth = leftWidth;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_splitView setPosition:savedLeftWidth ofDividerAtIndex:0];
        [self->_terminalView updateSize];
    });

    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:_terminalView];

    // Start tick timer
    _tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0
                                                  target:self
                                                selector:@selector(tick)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)tick {
    if (_app) {
        ghostty_app_tick(_app);
    }
    if (_terminalView) {
        [_terminalView setNeedsDisplay:YES];
    }
}

- (void)applicationWillTerminate:(NSNotification *)notification {
    [_tickTimer invalidate];
    _tickTimer = nil;

    if (_app) {
        ghostty_app_free(_app);
        _app = NULL;
    }
    if (_config) {
        ghostty_config_free(_config);
        _config = NULL;
    }
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender {
    return YES;
}

@end
