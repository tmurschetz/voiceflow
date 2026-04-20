# ─── Configuration ────────────────────────────────────────────────────────────

SCHEME   = VoiceflowDesktop
PROJECT  = VoiceflowDesktop.xcodeproj
APP_NAME = Voiceflow          # User-visible name of the .app bundle
BUILD    = .build

# Paths derived from configuration
APP      = $(BUILD)/Release/$(APP_NAME).app
DMG      = $(APP_NAME)-beta.dmg

# Read version from Info.plist so the DMG reflects the current build number
VERSION  = $(shell /usr/libexec/PlistBuddy -c \
             "Print CFBundleShortVersionString" \
             VoiceflowDesktop/Resources/Info.plist 2>/dev/null || echo "0.1.0")

.PHONY: generate open dev build clean \
        build-release dmg install \
        deps help

# ─── Developer workflow ───────────────────────────────────────────────────────

## Generate Xcode project from project.yml
generate:
	xcodegen generate

## Open Xcode (generates first)
open: generate
	open $(PROJECT)

## Generate + open (typical dev shortcut)
dev: generate open

## Build Debug from the command line (for CI / quick check)
build: generate
	xcodebuild \
		-project $(PROJECT) \
		-scheme  $(SCHEME)  \
		-configuration Debug \
		-derivedDataPath $(BUILD)/DerivedData \
		build

## Remove all build artefacts
clean:
	rm -rf $(BUILD) $(DMG)
	rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceflowDesktop-*
	rm -rf $(PROJECT)

## SPM packages are resolved by Xcode on first open
deps:
	@echo "SPM packages (KeyboardShortcuts, Sparkle) are fetched automatically."
	@echo "Run 'make open' to generate the project and let Xcode resolve them."

# ─── Distribution ─────────────────────────────────────────────────────────────
#
# Internal beta (no Apple Developer account required):
#   make dmg       →  Voiceflow-beta.dmg  (ad-hoc signed, share with trusted users)
#   make install   →  installs directly to /Applications on THIS Mac
#
# First-launch note for recipients:
#   Right-click Voiceflow.app → Open → "Open" in the Gatekeeper dialog.
#   OR run in Terminal:  xattr -cr /Applications/Voiceflow.app
#
# Proper public distribution (requires Apple Developer Program, $99/yr):
#   See README.md → "Phase 2: Public Distribution"
# ─────────────────────────────────────────────────────────────────────────────

## Build a Release .app with ad-hoc signing (no Developer account needed)
build-release: generate
	@echo "→  Building $(APP_NAME) $(VERSION) — Release / ad-hoc signed…"
	@mkdir -p $(BUILD)/Release
	xcodebuild \
		-project $(PROJECT) \
		-scheme  $(SCHEME)  \
		-configuration Release \
		-derivedDataPath $(BUILD)/DerivedData \
		CONFIGURATION_BUILD_DIR="$(CURDIR)/$(BUILD)/Release" \
		PRODUCT_NAME="$(APP_NAME)" \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGN_STYLE=Manual \
		build \
		| grep -E "(error:|warning: |Build succeeded|BUILD SUCCEEDED|BUILD FAILED)" || true
	@test -d "$(APP)" && echo "✅  Built: $(APP)" \
	  || (echo "❌  Build failed — run 'make build-release' without grep to see full output" && exit 1)

## Package the Release .app as a drag-install DMG
##   Output: Voiceflow-beta.dmg (uses only macOS built-in hdiutil — no Homebrew needed)
dmg: build-release
	@echo "→  Packaging $(DMG) (v$(VERSION))…"
	@rm -rf "$(BUILD)/dmg-staging" "$(DMG)"
	@mkdir -p "$(BUILD)/dmg-staging"
	@cp -R "$(APP)" "$(BUILD)/dmg-staging/"
	@ln -s /Applications "$(BUILD)/dmg-staging/Applications"
	hdiutil create \
		-volname "$(APP_NAME)" \
		-srcfolder "$(BUILD)/dmg-staging" \
		-ov -format UDZO \
		-o "$(DMG)"
	@rm -rf "$(BUILD)/dmg-staging"
	@echo ""
	@echo "✅  $(DMG) is ready  (v$(VERSION))"
	@echo "   ┌─ To install: open the DMG, drag Voiceflow → Applications"
	@echo "   └─ First launch: right-click → Open  (or: xattr -cr /Applications/Voiceflow.app)"

## Build Release + install directly to /Applications on this Mac
install: build-release
	@echo "→  Installing to /Applications/$(APP_NAME).app…"
	@rm -rf "/Applications/$(APP_NAME).app"
	@cp -R "$(APP)" "/Applications/$(APP_NAME).app"
	@xattr -cr "/Applications/$(APP_NAME).app"
	@echo "✅  Installed. Launching…"
	@open "/Applications/$(APP_NAME).app"

## Print available targets
help:
	@echo ""
	@echo "Voiceflow Desktop — Makefile targets"
	@echo ""
	@echo "  make open          Generate project + open Xcode (daily dev)"
	@echo "  make build         Quick Debug build (no signing)"
	@echo "  make clean         Remove all build artefacts"
	@echo ""
	@echo "  make build-release Build signed Release .app"
	@echo "  make dmg           Build + package as Voiceflow-beta.dmg"
	@echo "  make install       Build + install to /Applications + launch"
	@echo ""
