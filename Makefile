SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

APP_NAME := BigBrother
APP := dist/BigBrother.app
DMG := dist/$(APP_NAME).dmg
BUILD_DIR := build
DMG_STAGING := $(BUILD_DIR)/dmg-staging
TARGET_OS := 13.0
ARCH := $(shell uname -m)
COMMIT_ID := $(shell git rev-parse --short HEAD 2>/dev/null)
CODESIGN_IDENTITY ?= -

.PHONY: all build dmg run test test-storage test-panel clean

all: build

build:
	@if [[ -z "$(COMMIT_ID)" ]]; then \
		echo "错误: 无法获取 Git commit ID"; \
		exit 1; \
	fi
	@echo "▸ 清理"
	@rm -rf "$(BUILD_DIR)" "$(APP)"
	@mkdir -p "$(BUILD_DIR)" "$(APP)/Contents/MacOS" "$(APP)/Contents/Resources"
	@echo "▸ 编译 ($(ARCH), macOS $(TARGET_OS)+)"
	xcrun --sdk macosx swiftc \
		-O -whole-module-optimization \
		-swift-version 5 \
		-disable-sandbox \
		-module-cache-path "$(BUILD_DIR)/modulecache" \
		-target "$(ARCH)-apple-macos$(TARGET_OS)" \
		-framework AppKit \
		-framework SwiftUI \
		-framework UserNotifications \
		-lsqlite3 \
		Sources/*.swift \
		-o "$(BUILD_DIR)/$(APP_NAME)"
	@echo "▸ 打包"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(APP)/Contents/MacOS/"
	@cp Resources/Info.plist "$(APP)/Contents/"
	@/usr/libexec/PlistBuddy -c "Add :BigBrotherCommit string $(COMMIT_ID)" "$(APP)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	@echo "▸ 代码签名"
	@if [[ "$(CODESIGN_IDENTITY)" == "-" ]]; then \
		codesign --force --sign - "$(APP)"; \
	else \
		codesign --force --options runtime --timestamp --sign "$(CODESIGN_IDENTITY)" "$(APP)"; \
	fi
	codesign --verify --strict "$(APP)"
	@echo "✓ 完成: $(APP)"

dmg: build
	@echo "▸ 准备 DMG"
	@rm -rf "$(DMG_STAGING)"
	@mkdir -p "$(DMG_STAGING)"
	@ditto "$(APP)" "$(DMG_STAGING)/$(APP_NAME).app"
	@ln -s /Applications "$(DMG_STAGING)/Applications"
	@echo "▸ 创建 DMG"
	hdiutil create -volname "$(APP_NAME)" -srcfolder "$(DMG_STAGING)" -ov -format UDZO "$(DMG)"
	@echo "✓ 完成: $(DMG)"

run: build
	@echo "▸ 启动 $(APP_NAME)"
	@open "$(APP)"

test: build
	@if [[ -z "$(strip $(LOGS))" ]]; then \
		echo "用法: make test LOGS='<日志文件> [...]'"; \
		exit 2; \
	fi
	@echo "▸ 命令行自检"
	@BIGBROTHER_DB="$${BIGBROTHER_DB:-$(CURDIR)/$(BUILD_DIR)/selftest.db}" \
		"$(APP)/Contents/MacOS/$(APP_NAME)" --scan $(LOGS)

test-storage:
	@mkdir -p "$(BUILD_DIR)"
	xcrun --sdk macosx swiftc -swift-version 5 -disable-sandbox \
		-module-cache-path "$(BUILD_DIR)/modulecache" \
		-target "$(ARCH)-apple-macos$(TARGET_OS)" \
		-framework AppKit -framework SwiftUI -framework UserNotifications -lsqlite3 \
		$(filter-out Sources/main.swift,$(wildcard Sources/*.swift)) \
		Tests/StorageTests.swift -o "$(BUILD_DIR)/StorageTests"
	"$(BUILD_DIR)/StorageTests"

test-panel:
	@mkdir -p "$(BUILD_DIR)"
	xcrun --sdk macosx swiftc -swift-version 5 -disable-sandbox \
		-module-cache-path "$(BUILD_DIR)/modulecache" \
		-target "$(ARCH)-apple-macos$(TARGET_OS)" \
		-framework AppKit -framework SwiftUI -framework UserNotifications -lsqlite3 \
		$(filter-out Sources/main.swift,$(wildcard Sources/*.swift)) \
		Tests/PanelLayoutTests.swift -o "$(BUILD_DIR)/PanelLayoutTests"
	"$(BUILD_DIR)/PanelLayoutTests"

clean:
	@rm -rf "$(BUILD_DIR)" dist
	@echo "✓ 已清理"
