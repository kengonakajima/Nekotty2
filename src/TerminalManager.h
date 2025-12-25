#import <Cocoa/Cocoa.h>
#import <ghostty.h>
#import "TerminalView.h"

@interface TerminalManager : NSObject

@property (nonatomic, readonly) NSArray<TerminalView *> *terminals;
@property (nonatomic, readonly) TerminalView *selectedTerminal;
@property (nonatomic, readonly) NSUInteger selectedIndex;

- (instancetype)initWithApp:(ghostty_app_t)app;
- (TerminalView *)createTerminalWithFrame:(NSRect)frame;
- (void)selectTerminalAtIndex:(NSUInteger)index;
- (void)selectTerminal:(TerminalView *)terminal;
- (void)removeTerminal:(TerminalView *)terminal;

@end
