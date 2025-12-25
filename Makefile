# Nekotty2 Makefile

APP_NAME = Nekotty2
APP_BUNDLE = $(APP_NAME).app

CC = clang
OBJC_FLAGS = -fobjc-arc -Wall
FRAMEWORKS = -framework Cocoa -framework Metal -framework MetalKit -framework QuartzCore \
             -framework IOSurface -framework Carbon -framework CoreText -framework CoreGraphics \
             -framework Security -framework UniformTypeIdentifiers
CXXLIBS = -lc++

# Ghostty paths
GHOSTTY_DIR = ../ghostty
GHOSTTY_INCLUDE = $(GHOSTTY_DIR)/include
# Find the universal binary (x86_64 + arm64) for macOS
GHOSTTY_LIB = $(shell for f in $$(find $(GHOSTTY_DIR)/.zig-cache -name "libghostty.a" 2>/dev/null); do \
	if lipo -info "$$f" 2>/dev/null | grep -q "x86_64 arm64"; then echo "$$f"; break; fi; \
done)

INCLUDES = -I$(GHOSTTY_INCLUDE)
LIBS = $(GHOSTTY_LIB)

SRC_DIR = src
BUILD_DIR = build
RESOURCES_DIR = Resources

SRCS = $(wildcard $(SRC_DIR)/*.m)
OBJS = $(SRCS:$(SRC_DIR)/%.m=$(BUILD_DIR)/%.o)

EXECUTABLE = $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)

.PHONY: all clean run

all: $(APP_BUNDLE)

$(APP_BUNDLE): $(EXECUTABLE) $(APP_BUNDLE)/Contents/Info.plist
	@echo "Build complete: $(APP_BUNDLE)"

$(EXECUTABLE): $(OBJS) | $(APP_BUNDLE)/Contents/MacOS
	$(CC) $(OBJC_FLAGS) $(FRAMEWORKS) $(CXXLIBS) -o $@ $(OBJS) $(LIBS)

$(BUILD_DIR)/%.o: $(SRC_DIR)/%.m | $(BUILD_DIR)
	$(CC) $(OBJC_FLAGS) $(INCLUDES) -c -o $@ $<

$(APP_BUNDLE)/Contents/Info.plist: $(RESOURCES_DIR)/Info.plist | $(APP_BUNDLE)/Contents
	cp $< $@

$(BUILD_DIR):
	mkdir -p $(BUILD_DIR)

$(APP_BUNDLE)/Contents:
	mkdir -p $(APP_BUNDLE)/Contents

$(APP_BUNDLE)/Contents/MacOS:
	mkdir -p $(APP_BUNDLE)/Contents/MacOS

clean:
	rm -rf $(BUILD_DIR) $(APP_BUNDLE)

run: $(APP_BUNDLE)
	open $(APP_BUNDLE)
