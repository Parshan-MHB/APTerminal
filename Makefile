SHELL := /bin/zsh

DERIVED_DATA := $(CURDIR)/.build/xcode-derived-data
DIST_DIR := $(CURDIR)/dist
MAC_APP_BUNDLE := $(DIST_DIR)/APTerminal.app

.PHONY: help generate build-package test build-mac build-mac-unsigned package-mac-app build-ios build-all clean-dist

help:
	@echo "Available targets:"
	@echo "  generate      Regenerate the Xcode project from project.yml"
	@echo "  build-package Build the shared Swift package"
	@echo "  test          Run the full Swift package test suite"
	@echo "  build-mac     Build the macOS app target"
	@echo "  build-mac-unsigned Build the macOS app target without signing into local DerivedData"
	@echo "  package-mac-app Build and copy a runnable APTerminal.app into ./dist"
	@echo "  build-ios     Build the iOS app target for Simulator"
	@echo "  build-all     Generate the project and build both native app targets"
	@echo "  clean-dist    Remove packaged app artifacts from ./dist"

generate:
	rm -rf APTerminal.xcodeproj
	xcodegen generate

build-package:
	swift build

test:
	swift test

build-mac:
	xcodebuild -project APTerminal.xcodeproj -scheme MacCompanion -configuration Debug -destination 'platform=macOS' build

build-mac-unsigned:
	xcodebuild -project APTerminal.xcodeproj -scheme MacCompanion -configuration Debug -destination 'platform=macOS' -derivedDataPath '$(DERIVED_DATA)' build CODE_SIGNING_ALLOWED=NO

package-mac-app: generate build-mac-unsigned
	mkdir -p '$(DIST_DIR)'
	rm -rf '$(MAC_APP_BUNDLE)'
	cp -R '$(DERIVED_DATA)/Build/Products/Debug/APTerminal.app' '$(MAC_APP_BUNDLE)'
	@echo "Packaged app: $(MAC_APP_BUNDLE)"

build-ios:
	xcodebuild -project APTerminal.xcodeproj -scheme iOSClient -configuration Debug -destination 'generic/platform=iOS Simulator' build

build-all: generate build-mac build-ios

clean-dist:
	rm -rf '$(DIST_DIR)'
