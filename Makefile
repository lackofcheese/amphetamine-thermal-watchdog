PRODUCT := amphetamine-thermal-watchdog
SOURCE := Sources/AmphetamineThermalGuard/main.m
BUILD_DIR := build
BIN := $(BUILD_DIR)/$(PRODUCT)
MODULE_CACHE := $(BUILD_DIR)/module-cache

.PHONY: all clean test install uninstall

all: $(BIN)

$(BIN): $(SOURCE)
	mkdir -p $(BUILD_DIR) $(MODULE_CACHE)
	env CLANG_MODULE_CACHE_PATH=$(abspath $(MODULE_CACHE)) \
		xcrun clang -fobjc-arc -fblocks -framework Foundation -framework AppKit \
		-o $@ $<

test: $(BIN)
	scripts/test.sh $(BIN)

install: $(BIN)
	scripts/install.sh $(BIN)

uninstall:
	scripts/uninstall.sh

clean:
	rm -rf $(BUILD_DIR)
