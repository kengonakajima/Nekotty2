#import "TerminalManager.h"

@implementation TerminalManager {
    ghostty_app_t _app;
    NSMutableArray<TerminalView *> *_terminals;
    NSUInteger _selectedIndex;
}

- (instancetype)initWithApp:(ghostty_app_t)app {
    self = [super init];
    if (self) {
        _app = app;
        _terminals = [NSMutableArray array];
        _selectedIndex = NSNotFound;
    }
    return self;
}

- (NSArray<TerminalView *> *)terminals {
    return [_terminals copy];
}

- (TerminalView *)selectedTerminal {
    if (_selectedIndex == NSNotFound || _selectedIndex >= _terminals.count) {
        return nil;
    }
    return _terminals[_selectedIndex];
}

- (NSUInteger)selectedIndex {
    return _selectedIndex;
}

- (TerminalView *)createTerminalWithFrame:(NSRect)frame {
    TerminalView *terminal = [[TerminalView alloc] initWithApp:_app frame:frame];
    if (terminal) {
        [_terminals addObject:terminal];
        if (_selectedIndex == NSNotFound) {
            _selectedIndex = 0;
        }
        NSLog(@"Created terminal %lu, total: %lu", (unsigned long)(_terminals.count - 1), (unsigned long)_terminals.count);
    }
    return terminal;
}

- (void)selectTerminalAtIndex:(NSUInteger)index {
    if (index < _terminals.count) {
        _selectedIndex = index;
        NSLog(@"Selected terminal %lu", (unsigned long)index);
    }
}

- (void)selectTerminal:(TerminalView *)terminal {
    NSUInteger index = [_terminals indexOfObject:terminal];
    if (index != NSNotFound) {
        _selectedIndex = index;
        NSLog(@"Selected terminal %lu", (unsigned long)index);
    }
}

- (void)removeTerminal:(TerminalView *)terminal {
    NSUInteger index = [_terminals indexOfObject:terminal];
    if (index != NSNotFound) {
        [_terminals removeObjectAtIndex:index];
        if (_terminals.count == 0) {
            _selectedIndex = NSNotFound;
        } else if (_selectedIndex >= _terminals.count) {
            _selectedIndex = _terminals.count - 1;
        }
        NSLog(@"Removed terminal, remaining: %lu", (unsigned long)_terminals.count);
    }
}

@end
