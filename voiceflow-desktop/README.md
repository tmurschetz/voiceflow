# Voiceflow Desktop

macOS menu bar dictation app. Press a shortcut, speak, get the result inserted into whatever you were typing — in Private, Business, or Calm mode.

**Platform:** macOS 13 Ventura or later  
**Backend:** Supabase (`uvoxbqqxrsqjdcljhjvk.supabase.co`) — existing Lovable project

---

## Installing the app (non-developer)

### What you receive

A file called **`Voiceflow-beta.dmg`**.

### Install steps

1. Double-click `Voiceflow-beta.dmg`
2. Drag **Voiceflow** into the **Applications** folder shown in the window
3. Eject the DMG (drag it to Trash or press ⌘E)
4. Open **Voiceflow** from your Applications folder or Spotlight

### First-launch Gatekeeper prompt

Because the app is not yet signed with a paid Apple certificate, macOS will block
it on the first open. Fix it in one of two ways:

**Option A — right-click:**
Right-click (or Control-click) `Voiceflow.app` → **Open** → click **Open** in the dialog.
You only need to do this once.

**Option B — Terminal (one command):**
```
xattr -cr /Applications/Voiceflow.app
```
Then open the app normally.

### First-run permissions

On first launch Voiceflow will ask for three permissions:

| Permission | Why it's needed |
|---|---|
| **Microphone** | To record your voice |
| **Speech Recognition** | To convert your voice to text (done on-device) |
| **Accessibility** | To insert text directly into the field you're typing in |

All three appear as system dialogs. Click **Allow** / **Grant Access** for each.  
If you miss one, go to **System Settings → Privacy & Security** and enable it there.

---

## Using the app

The app lives in your **menu bar** (top-right area of the screen).

| Action | What happens |
|---|---|
| Click the waveform icon | Opens the status panel |
| Press your shortcut once | Starts recording (icon turns red) |
| Press the same shortcut again | Stops recording, transcribes, processes, inserts text |
| Right-click the icon | Opens the utility menu (Settings, Updates, Sign Out) |

### Three modes

Each mode has its own keyboard shortcut, configurable in Settings:

| Mode | What it does |
|---|---|
| **Private** | Minimal correction — fixes punctuation and capitalisation only. Stays 100% on-device. |
| **Business** | Rewrites for a professional, customer-facing tone |
| **Calm** | De-escalates aggressive or frustrated wording |

---

## Checking for updates

Right-click the Voiceflow icon in the menu bar → **Check for Updates…**

> During the internal beta, the update server is not yet live. This menu item is
> prepared for when updates are published. For now, install new versions by
> downloading a new DMG.

---

## Building the app yourself

Prerequisites: **Xcode 15+** and `brew install xcodegen`

```bash
cd voiceflow-desktop

make open          # generate project + open Xcode (first time)
# Set your Apple Developer Team in Signing & Capabilities, then ⌘R

make build-release # build a Release .app (ad-hoc signed, no Developer account needed)
make dmg           # build + package as Voiceflow-beta.dmg  ← share this
make install       # build + install directly to /Applications + launch
```

The DMG is produced using only macOS built-in tools — no Homebrew required for packaging.

---

## Distribution: phase 1 vs phase 2

### Phase 1 — Internal beta (now, no Apple account needed)

| What | How |
|---|---|
| Build | `make dmg` → `Voiceflow-beta.dmg` |
| Signing | Ad-hoc (`-`) — works on your Mac, shareable with trusted users |
| Gatekeeper | Users right-click → Open once |
| Updates | Share a new DMG manually |

This is the current state of the project.

### Phase 2 — Proper distribution (future, requires Apple Developer Program)

Cost: $99/year at [developer.apple.com](https://developer.apple.com)

Steps to unlock full public distribution:

1. **Enrol in Apple Developer Program**
2. **Create a Developer ID Application certificate** in Xcode → Settings → Accounts
3. **Set Team ID** in `project.yml` (`DEVELOPMENT_TEAM: YOURTEAMID`)
4. **Notarize** the app after building:
   ```bash
   xcrun notarytool submit Voiceflow-beta.dmg \
     --apple-id your@email.com \
     --team-id YOURTEAMID \
     --password <app-specific-password> \
     --wait
   xcrun stapler staple Voiceflow-beta.dmg
   ```
5. **Set up a Sparkle appcast** (the auto-update feed):
   - Host an `appcast.xml` at the URL in `Info.plist → SUFeedURL`
   - Generate EdDSA keys: run `generate_keys` from the Sparkle package
   - Set the public key in `Info.plist → SUPublicEDKey`
   - Sign each release binary with `sign_update`
   - Users will then receive silent automatic updates inside the app

Once notarized, Gatekeeper accepts the app on any Mac without any extra steps.

---

## Auto-update architecture (Sparkle)

The app uses **[Sparkle 2](https://sparkle-project.org)** — the standard native macOS
auto-update framework (used by Transmit, BBEdit, and hundreds of other Mac apps).

How it works:
1. On launch, Sparkle fetches `appcast.xml` from `SUFeedURL`
2. If a newer version is listed, it prompts the user
3. User clicks **Install and Relaunch** — Sparkle downloads, verifies, and swaps the app
4. Updates are signed with EdDSA — only you can publish them

Current status: Sparkle is wired and the menu item exists. The appcast server needs
to be set up before updates can be delivered (Phase 2).

---

## Architecture

```
VoiceflowDesktop/
├── App/
│   ├── VoiceflowDesktopApp.swift      # @main entry, NSApplicationDelegate adapter
│   └── AppDelegate.swift              # Startup sequence, dictation pipeline, Sparkle
│
├── Core/
│   ├── Auth/AuthService.swift         # Sign-in, token refresh (fixed), Keychain
│   ├── Settings/
│   │   ├── AppSettings.swift          # Settings model + enums
│   │   └── SettingsService.swift      # Load (GET) + Save (PATCH/POST) user_settings
│   ├── Recording/RecordingService.swift     # AVFoundation — default + device-specific
│   ├── Transcription/TranscriptionService.swift  # SFSpeechRecognizer, on-device
│   ├── Processing/ModeProcessor.swift       # Edge function call + fallback
│   ├── Output/OutputService.swift           # AX insert → CGEventPost ⌘V → clipboard
│   └── Logging/SessionLogger.swift          # POST to transcription_sessions
│
├── Network/
│   ├── APIClient.swift                # URLSession wrapper, auth headers
│   ├── Endpoints.swift                # All Supabase paths (schema-verified)
│   ├── BackendSchema.swift            # Canonical schema reference (documentation)
│   └── Models/
│       ├── UserProfile.swift          # profiles + user_roles + auth types
│       └── TranscriptionSession.swift # transcription_sessions insert model
│
├── Features/
│   ├── MenuBar/MenuBarController.swift      # NSStatusItem, left/right-click handling
│   ├── StatusPanel/
│   │   ├── StatusPanelViewModel.swift # AppState, BlockedReason
│   │   └── StatusPanelView.swift      # Compact popover panel
│   ├── Login/                         # Email/password sign-in window
│   └── Settings/                      # Full settings window + ViewModel
│
├── Shortcuts/ShortcutManager.swift    # Global hotkeys (KeyboardShortcuts)
├── Permissions/PermissionsManager.swift  # Mic + Speech + Accessibility guidance
└── Resources/
    ├── Info.plist                     # SUFeedURL + SUPublicEDKey for Sparkle
    └── VoiceflowDesktop.entitlements
```

---

## Backend

| | |
|---|---|
| URL | `https://uvoxbqqxrsqjdcljhjvk.supabase.co` |
| Auth | Email + password → Supabase Auth v2 |
| Token storage | macOS Keychain |
| Schema verified | 2026-04-20 via PostgREST column probing |

### Startup sequence

```
1. Load session from Keychain
2. POST /auth/v1/token?grant_type=refresh_token  →  refresh JWT
3. GET  /rest/v1/profiles?user_id=eq.<id>        →  fetch profile
   └─ profile.status must be 'active' — pending/suspended/rejected → blocked screen
4. GET  /rest/v1/user_roles?user_id=eq.<id>      →  fetch role (informational)
5. GET  /rest/v1/user_settings?user_id=eq.<id>   →  load settings
6. Register global shortcuts
7. Request Microphone + Speech + Accessibility permissions
```

### Verified table schemas

| Table | Key columns |
|---|---|
| `profiles` | `user_id` (filter), `status` (enum: active/pending/suspended/rejected) |
| `user_roles` | `user_id`, `role` — 3 columns only, no timestamps |
| `user_settings` | 14 columns incl. all shortcut/language/output/microphone settings |
| `transcription_sessions` | 19 columns — append-only log after each dictation |
| `style_profiles` | `name`, `description`, `is_default`, `active` — not yet read by desktop |

See `Network/BackendSchema.swift` for the complete verified column list.

---

## Dependencies

| Package | Purpose |
|---|---|
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | Global hotkey registration |
| [Sparkle 2](https://github.com/sparkle-project/Sparkle) | Native macOS auto-update |

All other functionality uses Apple system frameworks: AVFoundation, Speech,
ApplicationServices, AppKit, SwiftUI, Security, CoreAudio, CoreGraphics.
