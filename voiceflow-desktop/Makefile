# ─── Configuration ────────────────────────────────────────────────────────────

SCHEME   = VoiceflowDesktop
PROJECT  = VoiceflowDesktop.xcodeproj
# User-visible name of the .app bundle
APP_NAME = Voiceflow
BUILD    = .build

# Paths derived from configuration
APP      = $(BUILD)/Release/$(APP_NAME).app
DMG      = $(APP_NAME)-$(VERSION).dmg

VERSION  = 1.1.2

# ─── Code signing ─────────────────────────────────────────────────────────────
# SIGN_IDENTITY defaults to "-" (ad-hoc, no Apple account). The `release` target
# overrides it with the Developer ID for a notarised public build.
SIGN_IDENTITY ?= -
TEAM_ID        = GD42PF6FBY
DEV_ID         = Developer ID Application: Thomas Murschetz ($(TEAM_ID))
NOTARY_PROFILE = voiceflow-notary
RELEASE_ENT    = VoiceflowDesktop/Resources/VoiceflowDesktop-release.entitlements

.PHONY: generate open dev build clean \
        build-release dmg dmg-package install release notarize-check \
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
	@# Google Drive / Finder add extended attributes to files under .build/ —
	@# codesign then fails with "resource fork … detritus not allowed". Strip
	@# them up front (same guard as build-release).
	@xattr -cr "$(BUILD)/DerivedData" 2>/dev/null || true
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
	@# Log to file and HARD-FAIL on build errors — piping through grep used to
	@# swallow the exit code, so a failed build silently re-shipped the stale
	@# app from a previous Release build (bit us on 2026-07-22).
	@xcodebuild \
		-project $(PROJECT) \
		-scheme  $(SCHEME)  \
		-configuration Release \
		-derivedDataPath $(BUILD)/DerivedData \
		PRODUCT_NAME="$(APP_NAME)" \
		CODE_SIGN_IDENTITY="-" \
		CODE_SIGN_STYLE=Manual \
		PROVISIONING_PROFILE_SPECIFIER="" \
		CODE_SIGN_ENTITLEMENTS="" \
		build > "$(BUILD)/xcodebuild-release.log" 2>&1 \
	  || { grep -E "error:" "$(BUILD)/xcodebuild-release.log" | head -8; \
	       echo "❌  Release-Build fehlgeschlagen — komplettes Log: $(BUILD)/xcodebuild-release.log"; exit 1; }
	@grep -E "BUILD SUCCEEDED" "$(BUILD)/xcodebuild-release.log" | head -1
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
	@# ── Step 5: re-sign inside-out (frameworks → app) ────────────────────────
	@# Ad-hoc (SIGN_IDENTITY=-): uses the adhoc entitlements with
	@# disable-library-validation (frameworks re-signed ad-hoc carry no Team ID).
	@# Developer ID (release): Hardened Runtime + secure timestamp + the minimal
	@# release entitlements — library validation passes because every framework
	@# is signed with the same identity.
	@echo "   Code-signing as: $(SIGN_IDENTITY)…"
	@APP="$(CURDIR)/$(APP)"; \
	  if [ "$(SIGN_IDENTITY)" = "-" ]; then \
	    ENT="$(CURDIR)/VoiceflowDesktop/Resources/VoiceflowDesktop-adhoc.entitlements"; OPTS=""; \
	  else \
	    ENT="$(CURDIR)/$(RELEASE_ENT)"; OPTS="--options runtime --timestamp"; \
	  fi; \
	  find "$$APP/Contents" \( -name "*.framework" -o -name "*.dylib" -o -name "*.bundle" \) 2>/dev/null | while read item; do \
	    codesign --force $$OPTS --sign "$(SIGN_IDENTITY)" "$$item" 2>/dev/null; \
	  done; \
	  codesign --force $$OPTS --sign "$(SIGN_IDENTITY)" --entitlements "$$ENT" "$$APP"
	@echo "   ✓ signed"
	@test -f "$(APP)/Contents/MacOS/$(APP_NAME)" && echo "✅  Built: $(APP)" \
	  || (echo "❌  Build failed — run 'make build-release' without grep to see full output" && exit 1)

## Package the (already-built) Release .app into a drag-install DMG.
## Does NOT rebuild — `release` calls this after signing+notarising the app.
dmg-package:
	@echo "→  Packaging $(DMG) (v$(VERSION))…"
	@rm -rf "$(BUILD)/dmg-staging" "$(DMG)"
	@mkdir -p "$(BUILD)/dmg-staging"
	@cp -R "$(APP)" "$(BUILD)/dmg-staging/"
	@cp INSTALL.md "$(BUILD)/dmg-staging/" 2>/dev/null || true
	@ln -s /Applications "$(BUILD)/dmg-staging/Applications"
	hdiutil create \
		-volname "$(APP_NAME)" \
		-srcfolder "$(BUILD)/dmg-staging" \
		-ov -format UDZO \
		-o "$(DMG)"
	@rm -rf "$(BUILD)/dmg-staging"
	@echo "✅  $(DMG) is ready  (v$(VERSION))"

## Build (ad-hoc) + package — the internal-beta DMG (no Apple account needed).
dmg: build-release
	@$(MAKE) dmg-package
	@echo "   ┌─ To install: open the DMG, drag Voiceflow → Applications"
	@echo "   └─ First launch: right-click → Open  (or: xattr -cr /Applications/Voiceflow.app)"

# ─── Public release (Developer ID + notarisation) ─────────────────────────────
#
# One-time setup (creates the notary credential in YOUR keychain — needs an
# app-specific password from appleid.apple.com → Sign-In and Security):
#
#   xcrun notarytool store-credentials voiceflow-notary \
#       --apple-id you@example.com --team-id GD42PF6FBY
#
# Then every release is simply:  make release
#   → builds Developer-ID-signed (Hardened Runtime) → notarises → staples →
#     packages a clean DMG that opens with no Gatekeeper warning, anywhere.

## Verify the Developer ID cert + notary credential are in place.
notarize-check:
	@security find-identity -v -p codesigning | grep -q "$(DEV_ID)" \
	  || { echo "❌  Developer ID cert nicht gefunden ($(DEV_ID))."; exit 1; }
	@xcrun notarytool history --keychain-profile "$(NOTARY_PROFILE)" >/dev/null 2>&1 \
	  || { echo "❌  Notar-Zugang '$(NOTARY_PROFILE)' fehlt. Einmalig einrichten:"; \
	       echo "    xcrun notarytool store-credentials $(NOTARY_PROFILE) --apple-id <APPLE-ID> --team-id $(TEAM_ID)"; \
	       exit 1; }
	@echo "✅  Developer ID cert + Notar-Zugang vorhanden."

## Full public release: signed → notarised → stapled DMG.
release: notarize-check
	@echo "═══ Voiceflow $(VERSION) — signiertes & notarisiertes Release ═══"
	$(MAKE) build-release SIGN_IDENTITY="$(DEV_ID)"
	@echo "→  Verifiziere Signatur…"
	@codesign --verify --deep --strict --verbose=1 "$(APP)" && echo "   ✓ codesign ok"
	@echo "→  Notarisiere (kann 1–5 Min dauern)…"
	@ditto -c -k --keepParent "$(APP)" "$(BUILD)/notarize.zip"
	xcrun notarytool submit "$(BUILD)/notarize.zip" --keychain-profile "$(NOTARY_PROFILE)" --wait
	@rm -f "$(BUILD)/notarize.zip"
	@echo "→  Staple das Ticket an die App…"
	xcrun stapler staple "$(APP)"
	@$(MAKE) dmg-package
	@# The DMG container gets the full treatment too: sign → notarize → staple.
	@# (Stapling only works on signed+notarized containers; the app inside is
	@# already notarized, so this second round is quick.)
	@echo "→  Signiere + notarisiere das DMG…"
	codesign --force --sign "$(DEV_ID)" --timestamp "$(DMG)"
	xcrun notarytool submit "$(DMG)" --keychain-profile "$(NOTARY_PROFILE)" --wait
	xcrun stapler staple "$(DMG)"
	@echo ""
	@echo "✅  Notarisiertes Release fertig: $(DMG)"
	@echo "    spctl-Check:" && spctl --assess --type open --context context:primary-signature -v "$(DMG)" 2>&1 | sed 's/^/    /' || true

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
