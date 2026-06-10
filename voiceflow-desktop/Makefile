# ─── Configuration ────────────────────────────────────────────────────────────

SCHEME   = VoiceflowDesktop
PROJECT  = VoiceflowDesktop.xcodeproj
# User-visible name of the .app bundle
APP_NAME = Voiceflow
BUILD    = .build

# Paths derived from configuration
APP      = $(BUILD)/Release/$(APP_NAME).app
DMG      = $(APP_NAME)-beta.dmg

VERSION  = 0.3.0

.PHONY: generate open dev build clean \
        build-release dmg install \
        deps help icon release-notes

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
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGN_STYLE=Manual \
		CODE_SIGN_ENTITLEMENTS="" \
		build

## Remove all build artefacts
clean:
	rm -rf $(BUILD) $(DMG)
	rm -rf ~/Library/Developer/Xcode/DerivedData/VoiceflowDesktop-*
	rm -rf $(PROJECT)

## Build AppIcon.icns + monochrome MenuBarIcon.png set from AppIcon.png at repo root.
##   Drop a 1024×1024 PNG named AppIcon.png at the repo root, then run `make icon`.
icon:
	@scripts/make-icon.sh
	@python3 scripts/menubar-icon.py

## Update CHANGELOG.md from git history.
##   make release-notes                  → append commits since last tag to [Unreleased]
##   make release-notes RELEASE=0.3.0    → roll [Unreleased] into [0.3.0] dated today
##   make release-notes RELEASE=0.3.0 TAG=1 → also create git tag v0.3.0
release-notes:
	@scripts/release-notes.sh "$(RELEASE)" $(if $(TAG),--tag,)

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
#
# Background: XcodeGen generates a project with a Copy Files phase that embeds
# the KeyboardShortcuts_KeyboardShortcuts.bundle (SPM resource bundle for
# localised shortcut names). However, XcodeGen does not emit the accompanying
# bundle-build target, so xcodebuild cannot find the bundle to copy.
# Fix: pre-build the bundle from the SPM checkout before invoking xcodebuild.
build-release: generate
	@echo "→  Building $(APP_NAME) $(VERSION) — Release / ad-hoc signed…"
	@mkdir -p $(BUILD)/Release
	@# ── Step 1: resolve SPM packages so the checkout exists ──────────────────
	@echo "   Resolving SPM packages…"
	@xcodebuild -resolvePackageDependencies \
		-project $(PROJECT) \
		-scheme  $(SCHEME)  \
		-derivedDataPath $(BUILD)/DerivedData \
		2>&1 | grep -E "(error:|Resolved)" || true
	@# ── Step 2: strip Google Drive / Finder extended attributes ─────────────
	@# codesign rejects files with resource forks — common when working in
	@# Google Drive or after macOS Finder copies. Strip them from the entire
	@# DerivedData tree (SourcePackages + any cached build products).
	@echo "   Stripping extended attributes from DerivedData…"
	@xattr -cr "$(BUILD)/DerivedData" 2>/dev/null || true
	@# ── Step 2b: pre-build KeyboardShortcuts resource bundle ─────────────────
	@echo "   Pre-building KeyboardShortcuts resource bundle…"
	@BUNDLE_DST="$(BUILD)/DerivedData/Build/Products/Release/KeyboardShortcuts_KeyboardShortcuts.bundle"; \
	  LPROJ_SRC="$(BUILD)/DerivedData/SourcePackages/checkouts/KeyboardShortcuts/Sources/KeyboardShortcuts/Localization"; \
	  mkdir -p "$$BUNDLE_DST"; \
	  if [ -d "$$LPROJ_SRC" ]; then cp -R "$$LPROJ_SRC/"* "$$BUNDLE_DST/" 2>/dev/null; fi; \
	  xattr -cr "$$BUNDLE_DST" 2>/dev/null || true; \
	  echo "   ✓ bundle ready at $$BUNDLE_DST"
	@# ── Step 3: compile + link the app ───────────────────────────────────────
	xcodebuild \
		-project $(PROJECT) \
		-scheme  $(SCHEME)  \
		-configuration Release \
		-derivedDataPath $(BUILD)/DerivedData \
		PRODUCT_NAME="$(APP_NAME)" \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGN_STYLE=Manual \
		PROVISIONING_PROFILE_SPECIFIER="" \
		CODE_SIGN_ENTITLEMENTS="" \
		build \
		| grep -E "(error:|warning: |Build succeeded|BUILD SUCCEEDED|BUILD FAILED)" || true
	@# ── Step 4: copy the assembled .app to our well-known output path ────────
	@rm -rf "$(APP)"
	@cp -R "$(BUILD)/DerivedData/Build/Products/Release/$(APP_NAME).app" "$(APP)"
	@# ── Step 4b: ensure AppIcon.icns is present in Resources ────────────────
	@# XcodeGen bundles it via the resources rule, but we belt-and-braces copy
	@# in case the .icns was rebuilt after project generation.
	@if [ -f VoiceflowDesktop/Resources/AppIcon.icns ]; then \
	    cp VoiceflowDesktop/Resources/AppIcon.icns "$(APP)/Contents/Resources/AppIcon.icns"; \
	    echo "   ✓ AppIcon.icns copied"; \
	  else \
	    echo "   ⚠ No AppIcon.icns yet — drop AppIcon.png at repo root and run 'make icon'"; \
	  fi
	@for f in MenuBarIcon.png MenuBarIcon@2x.png MenuBarIcon@3x.png; do \
	    if [ -f "VoiceflowDesktop/Resources/$$f" ]; then \
	        cp "VoiceflowDesktop/Resources/$$f" "$(APP)/Contents/Resources/$$f"; \
	    fi; \
	  done
	@echo "   ✓ MenuBarIcon variants copied"
	@# ── Step 5: re-sign inside-out with ad-hoc + entitlements ────────────────
	@# macOS 14+ Hardened Runtime enforces library-validation: all loaded
	@# frameworks must share the main executable's Team ID.  Sparkle ships
	@# with its own Developer ID, so dyld refuses to load it ad-hoc unless
	@# com.apple.security.cs.disable-library-validation is present.
	@# We sign from the inside out: helper tools → Sparkle → app bundle.
	@echo "   Re-signing app bundle with adhoc entitlements (inside-out)…"
	@ADHOC_ENT="$(CURDIR)/VoiceflowDesktop/Resources/VoiceflowDesktop-adhoc.entitlements"; \
	  APP="$(CURDIR)/$(APP)"; \
	  find "$$APP/Contents/Frameworks" -name "*.framework" -maxdepth 1 | while read fw; do \
	    codesign --force --sign - "$$fw" 2>/dev/null; \
	  done; \
	  find "$$APP/Contents/Frameworks/Sparkle.framework" -name "*.xpc" -o -name "Autoupdate" -o -name "Updater" 2>/dev/null | while read tool; do \
	    codesign --force --sign - "$$tool" 2>/dev/null; \
	  done; \
	  codesign --force --sign - --entitlements "$$ADHOC_ENT" "$$APP"
	@echo "   ✓ signed"
	@test -f "$(APP)/Contents/MacOS/$(APP_NAME)" && echo "✅  Built: $(APP)" \
	  || (echo "❌  Build failed — run 'make build-release' without grep to see full output" && exit 1)

## Package the Release .app as a drag-install DMG
##   Output: Voiceflow-beta.dmg (uses only macOS built-in hdiutil — no Homebrew needed)
dmg: build-release
	@echo "→  Packaging $(DMG) (v$(VERSION))…"
	@rm -rf "$(BUILD)/dmg-staging" "$(DMG)"
	@mkdir -p "$(BUILD)/dmg-staging"
	@cp -R "$(APP)" "$(BUILD)/dmg-staging/"
	@cp INSTALL.md "$(BUILD)/dmg-staging/"
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
	@echo "  make icon          Build AppIcon.icns + monochrome MenuBarIcon set"
	@echo "  make release-notes Append commits since last tag to CHANGELOG.md"
	@echo "                     (RELEASE=x.y.z to roll [Unreleased] → [x.y.z])"
	@echo "  make build-release Build signed Release .app"
	@echo "  make dmg           Build + package as Voiceflow-beta.dmg"
	@echo "  make install       Build + install to /Applications + launch"
	@echo ""
