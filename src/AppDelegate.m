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
    if (action.tag == GHOSTTY_ACTION_PWD && target.tag == GHOSTTY_TARGET_SURFACE) {
        ghostty_surface_t surface = target.target.surface;
        NSString *pwd = action.action.pwd.pwd
            ? [NSString stringWithUTF8String:action.action.pwd.pwd]
            : nil;

        dispatch_async(dispatch_get_main_queue(), ^{
            // Find terminal by surface and update pwd
            AppDelegate *delegate = (AppDelegate *)[NSApp delegate];
            [delegate updatePwd:pwd forSurface:surface];
        });
        return true;
    }

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

static const CGFloat kThumbnailHeight = 40;  // 5 lines * 16pt * 0.5 scale = 40pt

@implementation AppDelegate {
    ghostty_app_t _app;
    ghostty_config_t _config;
    NSSplitView *_splitView;
    NSScrollView *_leftScrollView;
    NSView *_thumbnailContainer;
    NSMutableArray<NSView *> *_thumbnailViews;
    NSMutableArray<NSView *> *_projectHeaderViews;
    NSMutableSet<NSString *> *_foldedProjects;
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
    _projectHeaderViews = [NSMutableArray array];
    _foldedProjects = [NSMutableSet set];

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
            // Get current text content (first 10 lines, trimmed)
            // Use first lines instead of last, since content starts from top
            NSString *currentText = [[terminal lastLinesText:10 maxChars:80]
                stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceAndNewlineCharacterSet]];

            // Skip capture if content hasn't changed AND text is substantial
            // If text is too short, always recapture (content may be at top of screen)
            BOOL textIsSubstantial = (currentText.length > 20);
            BOOL textUnchanged = terminal.lastCapturedText && [currentText isEqualToString:terminal.lastCapturedText];

            if (textIsSubstantial && textUnchanged && terminal.cachedThumbnail) {
                [imageView setImage:terminal.cachedThumbnail];
                continue;
            }

            // Content changed or text too short - capture new thumbnail
            NSImage *image = [self captureTerminal:terminal];
            if (image) {
                [imageView setImage:image];
                terminal.cachedThumbnail = image;
                terminal.lastCapturedText = currentText;
            }
        }
    }
}

- (NSImage *)captureTerminal:(TerminalView *)terminal {
    if (!terminal || terminal.bounds.size.width <= 0 || terminal.bounds.size.height <= 0) {
        return nil;
    }
    if (!terminal.surface) {
        return nil;
    }

    // Temporarily show if hidden
    BOOL wasHidden = terminal.isHidden;
    [terminal setHidden:NO];

    // Force draw
    [terminal displayIfNeeded];

    // Get terminal grid info
    ghostty_surface_size_s gridSize = ghostty_surface_size(terminal.surface);
    CGFloat cellHeight = gridSize.cell_height_px / 2.0;  // Convert from pixels to points (2x retina)
    CGFloat cellWidth = gridSize.cell_width_px / 2.0;

    // Display at half size of main terminal
    CGFloat displayScale = 0.5;

    // Thumbnail target width (left pane width minus margins)
    CGFloat thumbWidth = _leftWidth - 16;

    // Calculate how many columns to show to fill thumbnail width
    CGFloat columnsToShow = (thumbWidth / displayScale) / cellWidth;
    columnsToShow = MIN(columnsToShow, gridSize.columns);

    // Show 5 lines
    CGFloat linesToShow = 5.0;
    linesToShow = MIN(linesToShow, gridSize.rows);

    // Calculate crop dimensions in points
    CGFloat cropWidth = columnsToShow * cellWidth;
    CGFloat cropHeight = linesToShow * cellHeight;

    NSRect termBounds = terminal.bounds;

    // Limit crop to actual terminal size
    CGFloat actualCropWidth = MIN(cropWidth, termBounds.size.width);
    CGFloat actualCropHeight = MIN(cropHeight, termBounds.size.height);

    // Create bitmap from view (full view)
    NSBitmapImageRep *bitmap = [terminal bitmapImageRepForCachingDisplayInRect:termBounds];
    if (bitmap) {
        [terminal cacheDisplayInRect:termBounds toBitmapImageRep:bitmap];

        // Scan bitmap to find lowest row with content (current prompt area)
        // Bitmap data: row 0 is at TOP of image (top-to-bottom storage)
        // Cocoa coords: origin at BOTTOM-LEFT (y increases upward)
        CGFloat scale = terminal.window ? terminal.window.backingScaleFactor : 2.0;
        NSInteger bitmapHeight = bitmap.pixelsHigh;
        NSInteger bitmapWidth = bitmap.pixelsWide;

        // Find the lowest (bottom-most) row with content
        // Scan from bitmap bottom (row height-1) to top (row 0)
        NSInteger lowestContentBitmapRow = 0; // Default to top of image
        unsigned char *bitmapData = [bitmap bitmapData];
        NSInteger bytesPerRow = [bitmap bytesPerRow];
        NSInteger samplesPerPixel = [bitmap samplesPerPixel];

        for (NSInteger row = bitmapHeight - 1; row >= 0; row--) {
            BOOL hasContent = NO;
            unsigned char *rowData = bitmapData + row * bytesPerRow;
            // Check a few columns for non-black pixels
            for (NSInteger col = 0; col < bitmapWidth && col < 100; col++) {
                unsigned char *pixel = rowData + col * samplesPerPixel;
                // Check if not background color (terminal bg is around 16,16,16)
                if (pixel[0] > 20 || pixel[1] > 20 || pixel[2] > 20) {
                    hasContent = YES;
                    break;
                }
            }
            if (hasContent) {
                lowestContentBitmapRow = row;
                break; // Found the bottom-most content row
            }
        }

        // Convert bitmap row to Cocoa Y coordinate
        // Bitmap row 0 = top of image = Cocoa Y (height-1)
        // Bitmap row (height-1) = bottom of image = Cocoa Y 0
        CGFloat lowestContentCocoaY = (bitmapHeight - 1 - lowestContentBitmapRow) / scale;

        // Crop 5 lines ending at the lowest content row
        // The lowest content row should be at the BOTTOM of the crop
        CGFloat cropBottom = lowestContentCocoaY;  // Start from the content row
        CGFloat cropTop = cropBottom + actualCropHeight;  // 5 lines above

        // Clamp to bounds
        if (cropBottom < 0) {
            cropBottom = 0;
            cropTop = actualCropHeight;
        }
        if (cropTop > termBounds.size.height) {
            cropTop = termBounds.size.height;
            cropBottom = cropTop - actualCropHeight;
        }

        NSRect srcRect = NSMakeRect(0, cropBottom, actualCropWidth, actualCropHeight);

        // Thumbnail size exactly matches cropped content at display scale
        CGFloat actualThumbWidth = actualCropWidth * displayScale;
        CGFloat actualThumbHeight = actualCropHeight * displayScale;

        NSImage *fullImage = [[NSImage alloc] initWithSize:termBounds.size];
        [fullImage addRepresentation:bitmap];

        NSImage *croppedImage = [[NSImage alloc] initWithSize:NSMakeSize(actualThumbWidth, actualThumbHeight)];
        [croppedImage lockFocus];
        [[NSGraphicsContext currentContext] setImageInterpolation:NSImageInterpolationHigh];
        [fullImage drawInRect:NSMakeRect(0, 0, actualThumbWidth, actualThumbHeight)
                     fromRect:srcRect
                    operation:NSCompositingOperationCopy
                     fraction:1.0];
        [croppedImage unlockFocus];

        // Restore hidden state
        [terminal setHidden:wasHidden];
        return croppedImage;
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

    // Edit menu
    NSMenuItem *editMenuItem = [[NSMenuItem alloc] init];
    NSMenu *editMenu = [[NSMenu alloc] initWithTitle:@"Edit"];
    [editMenu addItemWithTitle:@"Copy" action:@selector(copy:) keyEquivalent:@"c"];
    [editMenu addItemWithTitle:@"Paste" action:@selector(paste:) keyEquivalent:@"v"];
    [editMenuItem setSubmenu:editMenu];
    [mainMenu addItem:editMenuItem];

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

- (void)copy:(id)sender {
    // Copy is handled by clipboard callback from ghostty
}

- (void)paste:(id)sender {
    TerminalView *terminal = _terminalManager.selectedTerminal;
    if (!terminal || !terminal.surface) return;

    NSPasteboard *pb = [NSPasteboard generalPasteboard];
    NSString *str = [pb stringForType:NSPasteboardTypeString];
    if (str && str.length > 0) {
        const char *utf8 = [str UTF8String];
        if (utf8) {
            ghostty_surface_text(terminal.surface, utf8, strlen(utf8));
        }
    }
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

static const CGFloat kProjectHeaderHeight = 28;

- (void)layoutThumbnails {
    CGFloat spacing = 8;
    CGFloat margin = 8;
    CGFloat containerWidth = _leftWidth - margin * 2;

    // Remove old project headers
    for (NSView *header in _projectHeaderViews) {
        [header removeFromSuperview];
    }
    [_projectHeaderViews removeAllObjects];

    // Group terminals by project
    NSMutableDictionary<NSString *, NSMutableArray<TerminalView *> *> *projectGroups = [NSMutableDictionary dictionary];
    NSMutableArray<NSString *> *projectOrder = [NSMutableArray array];

    for (TerminalView *terminal in _terminalManager.terminals) {
        NSString *project = terminal.projectName ?: @"(unknown)";
        if (!projectGroups[project]) {
            projectGroups[project] = [NSMutableArray array];
            [projectOrder addObject:project];
        }
        [projectGroups[project] addObject:terminal];
    }

    // Calculate total height needed
    CGFloat totalHeight = margin;
    for (NSString *project in projectOrder) {
        totalHeight += kProjectHeaderHeight + spacing;
        if (![_foldedProjects containsObject:project]) {
            totalHeight += projectGroups[project].count * (kThumbnailHeight + spacing);
        }
    }
    CGFloat scrollHeight = _leftScrollView.bounds.size.height;
    if (totalHeight < scrollHeight) {
        totalHeight = scrollHeight;
    }

    // Update document view size
    [_thumbnailContainer setFrameSize:NSMakeSize(_leftWidth, totalHeight)];

    // Layout from top
    CGFloat y = totalHeight - margin;

    for (NSString *project in projectOrder) {
        // Create project header
        y -= kProjectHeaderHeight;
        NSView *header = [self createProjectHeaderForProject:project folded:[_foldedProjects containsObject:project]];
        [header setFrame:NSMakeRect(margin, y, containerWidth, kProjectHeaderHeight)];
        [_thumbnailContainer addSubview:header];
        [_projectHeaderViews addObject:header];
        y -= spacing;

        // Layout terminals in this project (if not folded)
        if (![_foldedProjects containsObject:project]) {
            for (TerminalView *terminal in projectGroups[project]) {
                // Find the thumbnail view for this terminal
                for (NSView *container in _thumbnailViews) {
                    NSString *terminalId = [NSString stringWithFormat:@"%p", terminal];
                    if ([container.identifier isEqualToString:terminalId]) {
                        y -= kThumbnailHeight;
                        [container setFrame:NSMakeRect(margin, y, containerWidth, kThumbnailHeight)];
                        [container setHidden:NO];
                        y -= spacing;
                        break;
                    }
                }
            }
        } else {
            // Hide thumbnails for folded projects
            for (TerminalView *terminal in projectGroups[project]) {
                for (NSView *container in _thumbnailViews) {
                    NSString *terminalId = [NSString stringWithFormat:@"%p", terminal];
                    if ([container.identifier isEqualToString:terminalId]) {
                        [container setHidden:YES];
                        break;
                    }
                }
            }
        }
    }
}

- (NSView *)createProjectHeaderForProject:(NSString *)project folded:(BOOL)folded {
    CGFloat containerWidth = _leftWidth - 16;
    NSView *header = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, containerWidth, kProjectHeaderHeight)];
    [header setWantsLayer:YES];
    [header.layer setBackgroundColor:[[NSColor colorWithWhite:0.25 alpha:1.0] CGColor]];
    [header.layer setCornerRadius:4.0];

    // Triangle indicator
    NSString *triangle = folded ? @"▶" : @"▼";
    NSTextField *indicator = [[NSTextField alloc] initWithFrame:NSMakeRect(8, 4, 16, 20)];
    [indicator setStringValue:triangle];
    [indicator setBezeled:NO];
    [indicator setDrawsBackground:NO];
    [indicator setEditable:NO];
    [indicator setSelectable:NO];
    [indicator setTextColor:[NSColor whiteColor]];
    [indicator setFont:[NSFont systemFontOfSize:12]];
    [header addSubview:indicator];

    // Project name label
    NSTextField *label = [[NSTextField alloc] initWithFrame:NSMakeRect(28, 4, containerWidth - 36, 20)];
    [label setStringValue:project];
    [label setBezeled:NO];
    [label setDrawsBackground:NO];
    [label setEditable:NO];
    [label setSelectable:NO];
    [label setTextColor:[NSColor whiteColor]];
    [label setFont:[NSFont boldSystemFontOfSize:13]];
    [header addSubview:label];

    // Click gesture for folding
    NSClickGestureRecognizer *click = [[NSClickGestureRecognizer alloc] initWithTarget:self action:@selector(projectHeaderClicked:)];
    [header addGestureRecognizer:click];
    [header setIdentifier:project];

    return header;
}

- (void)projectHeaderClicked:(NSClickGestureRecognizer *)gesture {
    NSView *header = gesture.view;
    NSString *project = header.identifier;

    if ([_foldedProjects containsObject:project]) {
        [_foldedProjects removeObject:project];
    } else {
        [_foldedProjects addObject:project];
    }

    [self layoutThumbnails];
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

- (void)updatePwd:(NSString *)pwd forSurface:(ghostty_surface_t)surface {
    for (TerminalView *terminal in _terminalManager.terminals) {
        if (terminal.surface == surface) {
            NSString *oldProject = terminal.projectName;
            terminal.pwd = pwd;
            NSString *newProject = terminal.projectName;

            // Re-layout if project changed
            if (![oldProject isEqualToString:newProject]) {
                [self layoutThumbnails];
            }
            break;
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
