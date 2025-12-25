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

static const CGFloat kThumbnailHeight = 100;

@implementation AppDelegate {
    ghostty_app_t _app;
    ghostty_config_t _config;
    NSSplitView *_splitView;
    NSScrollView *_leftScrollView;
    NSView *_thumbnailContainer;
    NSMutableArray<NSView *> *_thumbnailViews;
    NSView *_rightPane;
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

    // Create left pane (thumbnail list using simple NSView)
    NSRect leftFrame = NSMakeRect(0, 0, _leftWidth, contentBounds.size.height);
    _leftScrollView = [[NSScrollView alloc] initWithFrame:leftFrame];
    [_leftScrollView setHasVerticalScroller:YES];
    [_leftScrollView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [_leftScrollView setDrawsBackground:YES];
    [_leftScrollView setBackgroundColor:[NSColor colorWithWhite:0.15 alpha:1.0]];

    // Create container view for thumbnails
    _thumbnailContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, _leftWidth, contentBounds.size.height)];
    [_thumbnailContainer setWantsLayer:YES];
    _thumbnailViews = [NSMutableArray array];

    [_leftScrollView setDocumentView:_thumbnailContainer];

    // Create right pane (terminal container)
    NSRect rightFrame = NSMakeRect(0, 0, contentBounds.size.width - _leftWidth, contentBounds.size.height);
    _rightPane = [[NSView alloc] initWithFrame:rightFrame];
    [_rightPane setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];

    // Create first terminal
    [self createNewTerminal];

    // Add subviews to split view
    [_splitView addSubview:_leftScrollView];
    [_splitView addSubview:_rightPane];

    [[self.window contentView] addSubview:_splitView];

    // Set divider position after layout is complete
    dispatch_async(dispatch_get_main_queue(), ^{
        [self->_splitView setPosition:self->_leftWidth ofDividerAtIndex:0];
        [self showSelectedTerminal];
    });

    [self.window makeKeyAndOrderFront:nil];
    [self.window makeFirstResponder:_terminalManager.selectedTerminal];

    // Start tick timer
    _tickTimer = [NSTimer scheduledTimerWithTimeInterval:1.0/60.0
                                                  target:self
                                                selector:@selector(tick)
                                                userInfo:nil
                                                 repeats:YES];
}

- (void)tick {
    static int tickCount = 0;
    tickCount++;

    if (_app) {
        ghostty_app_tick(_app);
    }

    // Redraw all terminals
    for (TerminalView *terminal in _terminalManager.terminals) {
        [terminal setNeedsDisplay:YES];
    }

    // Update thumbnails every 10 ticks (~6 fps)
    if (tickCount % 10 == 0) {
        [self updateThumbnails];
    }
}

- (void)updateThumbnails {
    for (NSUInteger i = 0; i < _terminalManager.terminals.count; i++) {
        TerminalView *terminal = _terminalManager.terminals[i];
        NSView *container = _thumbnailViews[i];
        NSImageView *imageView = [container viewWithTag:1];

        if (imageView && terminal) {
            // Capture terminal content to image
            NSImage *image = [self captureTerminal:terminal];
            if (image) {
                [imageView setImage:image];
            }
        }
    }
}

- (NSImage *)captureTerminal:(TerminalView *)terminal {
    if (!terminal || terminal.bounds.size.width <= 0 || terminal.bounds.size.height <= 0) {
        return nil;
    }

    // Temporarily show if hidden
    BOOL wasHidden = terminal.isHidden;
    [terminal setHidden:NO];

    // Force draw
    [terminal displayIfNeeded];

    // Create bitmap from view
    NSBitmapImageRep *bitmap = [terminal bitmapImageRepForCachingDisplayInRect:terminal.bounds];
    if (bitmap) {
        [terminal cacheDisplayInRect:terminal.bounds toBitmapImageRep:bitmap];
        NSImage *image = [[NSImage alloc] initWithSize:terminal.bounds.size];
        [image addRepresentation:bitmap];

        // Restore hidden state
        [terminal setHidden:wasHidden];
        return image;
    }

    [terminal setHidden:wasHidden];
    return nil;
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
    [self createNewTerminal];
}

- (void)selectTerminalAtIndex:(NSUInteger)index {
    if (index >= _terminalManager.terminals.count) return;
    if (index == _terminalManager.selectedIndex) return;

    [_terminalManager selectTerminalAtIndex:index];
    [self showSelectedTerminal];
    [self.window makeFirstResponder:_terminalManager.selectedTerminal];
}

#pragma mark - Terminal Management

- (void)createNewTerminal {
    // Create terminal at full size in right pane
    TerminalView *terminal = [_terminalManager createTerminalWithFrame:_rightPane.bounds];
    if (!terminal) {
        NSLog(@"Failed to create terminal");
        return;
    }
    [terminal setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [terminal setHidden:YES]; // Initially hidden
    [_rightPane addSubview:terminal];

    // Create clickable container for thumbnail (with NSImageView)
    NSView *container = [self createThumbnailContainerForTerminal:terminal];
    [_thumbnailViews addObject:container];
    [_thumbnailContainer addSubview:container];
    [self layoutThumbnails];
    NSLog(@"Added container. Now have %lu thumbnails", (unsigned long)_thumbnailViews.count);

    // Select the new terminal
    [_terminalManager selectTerminal:terminal];
    [self showSelectedTerminal];
    [self.window makeFirstResponder:terminal];
}

- (void)layoutThumbnails {
    CGFloat spacing = 8;
    CGFloat margin = 8;
    CGFloat containerWidth = _leftWidth - margin * 2;

    // Calculate total height needed
    CGFloat totalHeight = margin + (_thumbnailViews.count * (kThumbnailHeight + spacing));
    CGFloat scrollHeight = _leftScrollView.bounds.size.height;
    if (totalHeight < scrollHeight) {
        totalHeight = scrollHeight;
    }

    // Update document view size
    [_thumbnailContainer setFrameSize:NSMakeSize(_leftWidth, totalHeight)];

    // Place items from top (in flipped coordinates, top = totalHeight - margin)
    CGFloat y = totalHeight - margin - kThumbnailHeight;
    for (NSView *container in _thumbnailViews) {
        [container setFrame:NSMakeRect(margin, y, containerWidth, kThumbnailHeight)];
        y -= kThumbnailHeight + spacing;
    }
}

- (NSView *)createThumbnailContainerForTerminal:(TerminalView *)terminal {
    CGFloat containerWidth = _leftWidth - 16;
    NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, containerWidth, kThumbnailHeight)];
    [container setWantsLayer:YES];
    [container.layer setBackgroundColor:[[NSColor colorWithWhite:0.1 alpha:1.0] CGColor]];
    [container.layer setBorderColor:[[NSColor grayColor] CGColor]];
    [container.layer setBorderWidth:1.0];
    [container.layer setCornerRadius:4.0];

    // Add NSImageView for thumbnail
    NSImageView *imageView = [[NSImageView alloc] initWithFrame:container.bounds];
    [imageView setAutoresizingMask:NSViewWidthSizable | NSViewHeightSizable];
    [imageView setImageScaling:NSImageScaleProportionallyUpOrDown];
    [imageView setTag:1]; // Tag to find it later
    [container addSubview:imageView];

    // Add click gesture
    NSClickGestureRecognizer *click = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(thumbnailClicked:)];
    [container addGestureRecognizer:click];

    // Store terminal reference in container
    [container setIdentifier:[NSString stringWithFormat:@"%p", terminal]];

    NSLog(@"Created thumbnail container: %.0fx%.0f for terminal %p", containerWidth, kThumbnailHeight, terminal);

    return container;
}

- (void)thumbnailClicked:(NSClickGestureRecognizer *)gesture {
    NSView *container = gesture.view;
    // Find the terminal by matching container identifier
    for (NSUInteger i = 0; i < _terminalManager.terminals.count; i++) {
        TerminalView *terminal = _terminalManager.terminals[i];
        NSString *terminalId = [NSString stringWithFormat:@"%p", terminal];
        if ([container.identifier isEqualToString:terminalId]) {
            [self selectTerminalAtIndex:i];
            break;
        }
    }
}

- (void)showSelectedTerminal {
    TerminalView *selected = _terminalManager.selectedTerminal;

    // Hide all terminals, show only selected
    for (TerminalView *t in _terminalManager.terminals) {
        [t setHidden:(t != selected)];
    }

    // Update size for selected terminal
    if (selected) {
        dispatch_async(dispatch_get_main_queue(), ^{
            [selected updateSize];
        });
    }

    // Update thumbnail borders to show selection
    [self updateThumbnailSelectionBorders];
}

- (void)updateThumbnailSelectionBorders {
    TerminalView *selected = _terminalManager.selectedTerminal;
    for (NSView *container in _thumbnailViews) {
        NSString *terminalId = [NSString stringWithFormat:@"%p", selected];
        if ([container.identifier isEqualToString:terminalId]) {
            [container.layer setBorderColor:[[NSColor selectedControlColor] CGColor]];
            [container.layer setBorderWidth:2.0];
        } else {
            [container.layer setBorderColor:[[NSColor grayColor] CGColor]];
            [container.layer setBorderWidth:1.0];
        }
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
