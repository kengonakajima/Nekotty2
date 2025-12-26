#import <Cocoa/Cocoa.h>
#import <ghostty.h>

@interface TerminalView : NSView <NSTextInputClient>

@property (nonatomic, assign) ghostty_surface_t surface;
@property (nonatomic, copy) NSString *pwd;
@property (nonatomic, readonly) NSString *projectName;
@property (nonatomic, copy) NSString *lastCapturedText;
@property (nonatomic, strong) NSImage *cachedThumbnail;
@property (nonatomic, assign) BOOL needsThumbnailUpdate;

- (instancetype)initWithApp:(ghostty_app_t)app frame:(NSRect)frame;
- (void)updateSize;
- (NSString *)lastLinesText:(int)lineCount maxChars:(int)maxChars;
- (NSString *)firstLinesText:(int)lineCount maxChars:(int)maxChars;

@end
