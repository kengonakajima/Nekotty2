#import "AppDelegate.h"
#import "TerminalView.h"
#import "TerminalManager.h"
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
    NSView *_rightPane;      // Container for terminal
    TerminalManager *_terminalManager;
    NSTimer *_tickTimer;
    CGFloat _leftWidth;
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

    // Create terminal manager
    _terminalManager = [[TerminalManager alloc] initWithApp:_app];

    // Setup menu
    [self setupMenu];

    // Create window
    _leftWidth = 300;
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
    NSRect leftFrame = NSMakeRect(0, 0, _leftWidth, contentBounds.size.height);
    _leftPane = [[NSView alloc] initWithFrame:leftFrame];
    [_leftPane setWantsLayer:YES];
    [_leftPane.layer setBackgroundColor:[[NSColor colorWithWhite:0.15 alpha:1.0] CGColor]];

    // Create right pane (terminal container)
    NSRect rightFrame = NSMakeRect(0, 0, contentBounds.size.width - _leftWidth, contentBounds.size.height);
    _rightPane = [[NSView alloc] initWithFrame:rightFrame];
    [_rightPane setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    // Create first terminal
    TerminalView *firstTerminal = [_terminalManager createTerminalWithFrame:_rightPane.bounds];
    if (!firstTerminal) {
        NSLog(@"Failed to create terminal view");
        return;
    }
    [firstTerminal setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_rightPane addSubview:firstTerminal];

    // Add subviews to split view
    [_splitView addSubview:_leftPane];
    [_splitView addSubview:_rightPane];

    [[self.window contentView] addSubview:_splitView];

    // Set divider position after layout is complete
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_splitView setPosition:self->_leftWidth ofDividerAtIndex:0];
        [self->_terminalManager.selectedTerminal updateSize];
    });

    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:firstTerminal];

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
    // Redraw all terminals
    for (TerminalView *terminal in _terminalManager.terminals) {
        [terminal setNeedsDisplay:YES];
    }
}

- (void)setupMenu {
    NSMenu *mainMenu = [[NSMenu alloc] init];

    // App menu
    NSMenuItem *appMenuItem = [[NSMenuItem alloc] init];
    NSMenu *appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit Nekotty" action:@selector(terminate:) keyEquivalent:@"q"];
    [appMenuItem setSubmenu:appMenu];
    [mainMenu addItem:appMenuItem];

    // Shell menu
    NSMenuItem *shellMenuItem = [[NSMenuItem alloc] init];
    NSMenu *shellMenu = [[NSMenu alloc] initWithTitle:@"Shell"];
    [shellMenu addItemWithTitle:@"New Tab" action:@selector(newTerminal:) keyEquivalent:@"t"];
    [shellMenuItem setSubmenu:shellMenu];
    [mainMenu addItem:shellMenuItem];

    [NSApp setMainMenu:mainMenu];
}

- (void)newTerminal:(id)sender {
    // Hide current terminal
    TerminalView *current = _terminalManager.selectedTerminal;
    if (current) {
        [current setHidden:YES];
    }

    // Create new terminal
    TerminalView *newTerminal = [_terminalManager createTerminalWithFrame:_rightPane.bounds];
    if (newTerminal) {
        [newTerminal setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
        [_rightPane addSubview:newTerminal];
        [_terminalManager selectTerminal:newTerminal];
        [self.window makeFirstResponder:newTerminal];

        dispatch_async(dispatch_get_main_queue(), ^{
            [newTerminal updateSize];
        });
    }
}

- (void)selectTerminalAtIndex:(NSUInteger)index {
    if (index >= _terminalManager.terminals.count) return;

    // Hide current terminal
    TerminalView *current = _terminalManager.selectedTerminal;
    if (current) {
        [current setHidden:YES];
    }

    // Show selected terminal
    [_terminalManager selectTerminalAtIndex:index];
    TerminalView *selected = _terminalManager.selectedTerminal;
    if (selected) {
        [selected setHidden:NO];
        [self.window makeFirstResponder:selected];
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
