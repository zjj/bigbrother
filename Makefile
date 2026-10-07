SHELL := /bin/bash
.SHELLFLAGS := -eu -o pipefail -c

APP_NAME := BigBrother
APP := dist/BigBrother.app
COMMIT_ID := $(shell git rev-parse --short HEAD 2>/dev/null)
DMG := dist/$(APP_NAME)-$(COMMIT_ID).dmg
BUILD_DIR := build
DMG_STAGING := $(BUILD_DIR)/dmg-staging
TARGET_OS := 13.0
ARCH := $(shell uname -m)
CODESIGN_IDENTITY ?= -

.PHONY: all icon build install dmg sign-dmg run test test-storage test-panel clean

PYTHON ?= $(shell for c in "$$DSH_PYTHON" \
	/Users/jj/.dsh/dsh-runtimes/dsh-primary-runtime/dependencies/python/bin/python3 \
	python3 python3.12 python3.11; do \
	[ -n "$$c" ] || continue; \
	p="$$(command -v "$$c" 2>/dev/null || echo "$$c")"; \
	[ -x "$$p" ] || continue; \
	"$$p" -c 'import PIL' 2>/dev/null || continue; \
	echo "$$p"; break; \
done)

all: build

# 应用图标:从 Resources/icon.png 生成 Resources/AppIcon.icns。
# 源图是「完全不透明的方图 + 一圈白边」,直接当图标用会在访达/通知里显示成
# 白底方块。这一步把它修成带透明边距、超椭圆圆角的标准形态,
# 已经是规范形态的源图则原样放行。详见 Tools/make-icon.py 的注释。
icon: Resources/AppIcon.icns

Resources/AppIcon.icns: Resources/icon.png Tools/make-icon.py
	@if [[ -z "$(PYTHON)" ]]; then \
		echo "错误: 生成图标需要带 Pillow 的 python3(例:python3 -m pip install pillow)"; \
		exit 1; \
	fi
	@$(PYTHON) Tools/make-icon.py

build: icon
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
	@cp Resources/AppIcon.icns "$(APP)/Contents/Resources/"
	@/usr/libexec/PlistBuddy -c "Add :BigBrotherCommit string $(COMMIT_ID)" "$(APP)/Contents/Info.plist"
	@printf 'APPL????' > "$(APP)/Contents/PkgInfo"
	@echo "▸ 代码签名", "$(CODESIGN_IDENTITY)"
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

sign-dmg:
	@set -e; \
	if [[ "$(origin CODESIGN_IDENTITY)" == "file" && "$(CODESIGN_IDENTITY)" == "-" ]]; then \
		identity_output="$$(security find-identity -v -p codesigning)"; \
		identities=(); \
		while IFS= read -r line; do \
			if [[ "$$line" =~ ^[[:space:]]*[0-9]+\)[[:space:]]+[[:xdigit:]]+[[:space:]]+\"(Developer\ ID\ Application:.*)\"$$ ]]; then \
				identities+=("$${BASH_REMATCH[1]}"); \
			fi; \
		done <<< "$$identity_output"; \
		case "$${#identities[@]}" in \
			0) echo "错误: 未找到有效的 Developer ID Application 身份"; echo "请先在 Xcode 或 Apple Developer 网站创建并安装证书"; exit 1 ;; \
			1) identity="$${identities[0]}"; echo "▸ 使用签名身份: $$identity" ;; \
			*) \
				if [[ ! -t 0 ]]; then echo "错误: 找到多个 Developer ID 身份，请交互运行 make sign-dmg 或显式设置 CODESIGN_IDENTITY"; exit 1; fi; \
				echo "请选择签名身份:"; \
				select identity in "$${identities[@]}"; do \
					if [[ -n "$$identity" ]]; then break; fi; \
					echo "无效选择，请重试"; \
				done ;; \
		esac; \
	else \
		identity="$(CODESIGN_IDENTITY)"; \
	fi; \
	$(MAKE) dmg CODESIGN_IDENTITY="$$identity"; \
	echo "▸ 签名 DMG"; \
	codesign --force --timestamp --sign "$$identity" "$(DMG)"; \
	codesign --verify --verbose=2 "$(DMG)"; \
	echo "✓ DMG 签名完成: $(DMG)"

# 装到 /Applications 并刷新图标缓存。
#
# 为什么要这一步:菜单栏应用的实际运行副本通常在 /Applications,而
# LaunchServices 的图标缓存按 bundle id 认路径 —— 只重建 dist/ 里的包,
# 访达/通知里看到的仍是旧副本(实测旧副本没有 CFBundleIconFile,图标是空的)。
install: build
	@echo "▸ 安装到 /Applications"
	@rm -rf "/Applications/$(APP_NAME).app"
	@ditto "$(APP)" "/Applications/$(APP_NAME).app"
	@/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "/Applications/$(APP_NAME).app"
	@echo "✓ 已安装: /Applications/$(APP_NAME).app"

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
