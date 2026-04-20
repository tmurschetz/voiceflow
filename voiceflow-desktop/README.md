# Voiceflow Desktop

macOS menu bar dictation app. Records speech, detects language, processes text in one of three modes, and inserts the result into the active text field.

**Platform:** macOS 13+  
**Backend:** https://uvoxbqqxrsqjdcljhjvk.supabase.co (existing Lovable project)

---

## Quick Start

```bash
cd voiceflow-desktop
make open        # generates VoiceflowDesktop.xcodeproj + opens Xcode
# Set Team in Signing & Capabilities, then ⌘R
```

Prerequisites: Xcode 15+, `brew install xcodegen`

The backend URL and anon key are already set in `Network/APIClient.swift` — no configuration needed.

---

## Architecture

```
VoiceflowDesktop/
├── App/
│   ├── VoiceflowDesktopApp.swift      # @main entry, NSApplicationDelegate adapter
│   └── AppDelegate.swift              # Startup sequence + dictation pipeline
│
├── Core/
│   ├── Auth/AuthService.swift         # Sign-in, token refresh, Keychain storage
│   ├── Settings/
│   │   ├── AppSettings.swift          # Settings model + enums
│   │   └── SettingsService.swift      # Load (GET) + Save (PATCH/POST) vs. user_settings
│   ├── Recording/RecordingService.swift     # AVFoundation audio capture
│   ├── Transcription/TranscriptionService.swift  # [scaffold] audio → transcript
│   ├── Processing/ModeProcessor.swift       # [scaffold] transcript + mode → text
│   ├── Output/OutputService.swift           # AX API insertion + clipboard fallback
│   └── Logging/SessionLogger.swift          # POST to transcription_sessions
│
├── Network/
│   ├── APIClient.swift                # URLSession wrapper, auth headers
│   ├── Endpoints.swift                # All Supabase paths
│   └── Models/
│       ├── UserProfile.swift          # profiles + user_roles + Supabase auth types
│       └── TranscriptionSession.swift # transcription_sessions insert model
│
├── Features/
│   ├── MenuBar/MenuBarController.swift       # NSStatusItem, icon states, popover
│   ├── StatusPanel/
│   │   ├── StatusPanelViewModel.swift # AppState + BlockedReason enums
│   │   └── StatusPanelView.swift      # Compact popover panel
│   ├── Login/LoginView + LoginViewModel      # Email/password sign-in
│   └── Settings/SettingsView + SettingsViewModel   # Full settings window
│
├── Shortcuts/ShortcutManager.swift    # Global hotkeys via KeyboardShortcuts pkg
├── Permissions/PermissionsManager.swift  # Mic + Accessibility permission guidance
└── Resources/
    ├── Info.plist
    └── VoiceflowDesktop.entitlements
```

---

## Backend Integration

### Connection

| Field | Value |
|-------|-------|
| Supabase URL | `https://uvoxbqqxrsqjdcljhjvk.supabase.co` |
| Anon key | Set in `Network/APIClient.swift` |
| Auth method | `POST /auth/v1/token?grant_type=password` (email + password) |
| Token refresh | `POST /auth/v1/token?grant_type=refresh_token` |
| Session storage | macOS Keychain (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`) |

### Startup Sequence

```
1. Load session from Keychain
2. POST /auth/v1/token?grant_type=refresh_token  → SupabaseSession
3. GET /rest/v1/profiles?user_id=eq.<auth.user.id>  → UserProfile
   - profile.status must be 'active' — anything else shows blocked screen
4. GET /rest/v1/user_roles?user_id=eq.<auth.user.id>  → UserRole (informational)
5. GET /rest/v1/user_settings?user_id=eq.<auth.user.id>  → AppSettings
6. Register global shortcuts
7. Request Microphone + Accessibility permissions
```

---

## Real Database Schema (Confirmed)

### `profiles`
| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | Table PK — **not** the auth user ID |
| `user_id` | uuid | FK → `auth.users.id` — **filter column for queries** |
| `email` | text | |
| `first_name` | text | |
| `last_name` | text | |
| `status` | text | `'pending'` \| `'active'` \| `'suspended'` \| `'rejected'` |
| `approved_at` | timestamptz | nullable |
| `approved_by` | uuid | nullable |
| `created_at` | timestamptz | |
| `updated_at` | timestamptz | |

**Schema delta from original assumption:** `display_name` → `first_name` + `last_name`. `id` is the table PK, `user_id` is the auth FK. Queries filter on `user_id`, not `id`.

### `user_roles`
| Column | Type | Notes |
|--------|------|-------|
| `id` | uuid | PK |
| `user_id` | uuid | FK → `auth.users.id` |
| `role` | text | `'pending_user'` \| `'active_user'` \| `'admin'` |

**Schema delta from original assumption:** Role was assumed to be on the `profiles` table. It is a separate table. The app fetches it separately (informational only — access control uses `profiles.status`).

### `user_settings`
| Column | Type | Desktop use |
|--------|------|------------|
| `id` | uuid | PK (DB-managed) |
| `user_id` | uuid | Filter + insert key |
| `shortcut_private` | text | `AppSettings.shortcutPrivate` |
| `shortcut_business` | text | `AppSettings.shortcutBusiness` |
| `shortcut_calm` | text | `AppSettings.shortcutCalm` |
| `auto_detect_language` | boolean | `AppSettings.autoDetectLanguage` |
| `manual_language_override` | text | `AppSettings.manualLanguageOverride.rawValue` |
| `output_mode` | text | Mapped via `OutputMode.fromDBValue()` / `.dbValue` |
| `microphone_device` | text | `AppSettings.microphoneDevice` |
| `auto_insert` | boolean | `AppSettings.autoInsert` |
| `default_language` | text | `AppSettings.defaultLanguage` |
| `default_mode` | text | `AppSettings.defaultMode` |
| `created_at` | timestamptz | DB-managed |
| `updated_at` | timestamptz | DB-managed |

**Schema deltas from original assumptions:**
- Column name: `microphone_device` (NOT `microphone_device_id`)
- `output_mode` default in DB is `'replace'` — **not** `'insert_into_field'`
- Three extra columns not in original assumption: `auto_insert`, `default_language`, `default_mode`
- All three are loaded and saved in the round-trip

**`output_mode` value mapping:**

| DB value | App enum | Behaviour |
|----------|----------|-----------|
| `'replace'` (default) | `.insertIntoField` | Insert at cursor / replace selection via AX API |
| `'clipboard'` | `.clipboardOnly` | Copy to clipboard only |
| Any other | `.insertIntoField` | Safe fallback |

**Save strategy:** PATCH if a settings row exists for the user; POST (insert) if not. The row existence is determined after `loadSettings()`. See `SettingsService.settingsRowExists`.

### `transcription_sessions`
| Column | Type | Set by |
|--------|------|--------|
| `id` | uuid | DB DEFAULT |
| `user_id` | uuid | App |
| `mode` | text | `'private'` \| `'business'` \| `'calm'` |
| `detected_language` | text | App (from transcription result) |
| `output_mode` | text | App (`OutputMode.dbValue`) |
| `started_at` | timestamptz | App (pipeline start time) |
| `finished_at` | timestamptz | App (pipeline end time) |
| `audio_seconds` | integer | App (from recording) |
| `success` | boolean | App |
| `error_message` | text | App (on failure) |
| `transcription_provider` | text | App (fill when wired) |
| `processing_provider` | text | App (fill when wired) |
| `raw_transcript` | text | App |
| `final_text` | text | App |
| `duration_seconds` | integer | App (wall-clock) |
| `word_count` | integer | App (computed) |
| `character_count` | integer | App (computed) |
| `status` | text | `'completed'` \| `'failed'` |
| `created_at` | timestamptz | DB DEFAULT NOW() |

**Schema deltas from original assumptions:** `language_detected` → `detected_language`. Added `started_at`, `finished_at`, `audio_seconds`, `success`, `error_message`, `raw_transcript`, `final_text`, `duration_seconds`, `word_count`, `character_count`, `status`. Use `TranscriptionSessionInsert.completed()` / `.failed()` convenience builders.

### `style_profiles` (read-only from desktop)
Global and user-specific AI style presets. Not yet used by the desktop app but available via `Endpoints.styleProfiles`.

---

## Blocked User States

The app enforces access at the profile status level:

| `profiles.status` | `BlockedReason` | User message |
|-------------------|-----------------|--------------|
| `'pending'` | `.pending` | Awaiting admin approval |
| `'suspended'` | `.suspended` | Account suspended |
| `'rejected'` | `.rejected` | Registration rejected |
| `'active'` | — | App is usable |

Users with any non-active status see a blocked screen in the menu bar popover. Global shortcuts are not registered for blocked users.

---

## Shortcut Validation

Before saving settings, `AppSettings.shortcutsAreValid` checks:
- No two **non-empty** shortcuts have the same value
- Empty shortcuts are allowed (means "not configured")

This intentionally allows partial shortcut configuration. The user can set one or two shortcuts without being forced to configure all three.

---

## What's Implemented vs. Scaffold

### ✅ Fully Implemented
- App lifecycle, menu bar utility, popover panel
- Login window (email/password → Supabase Auth v2)
- Session persistence in Keychain + automatic token refresh on startup
- User profile fetch using `user_id` filter (not `profiles.id`)
- Status check: active / pending / suspended / rejected → blocked state UI
- User role fetch from `user_roles` table
- Settings load (GET + local cache) with all real column names
- Settings save (PATCH for existing row, POST for new row)
- `output_mode` DB ↔ app enum mapping (`'replace'` ↔ `.insertIntoField`)
- Shortcut uniqueness validation (empty shortcuts allowed)
- Session logging schema wired to real `transcription_sessions` columns
- Five-state status panel (idle / recording / processing / success / error)
- Blocked state handling for all four non-active statuses
- Accessibility permission check + guidance
- Clipboard output
- AX API text insertion (works for native AppKit apps)

### 🔧 Scaffold (implement next)
- `TranscriptionService.transcribe()` — audio → transcript
- `ModeProcessor.process()` — transcript + mode → processed text
- Microphone device picker
- `ShortcutManager` DB sync (reading `KeyboardShortcuts` binding back to a string for DB)
- `CGEventPost` fallback for browser/Electron text fields
- `transcription_provider` / `processing_provider` fields filled once AI is wired

---

## Next 3 Implementation Steps

**1. Implement transcription (highest priority — nothing works without it)**

Option A — On-device (recommended for Private mode):
```swift
// In TranscriptionService.swift
import Speech
// SFSpeechRecognizer + SFSpeechAudioBufferRecognitionRequest
// Write audio Data to temp file, run recognizer, return transcript
```

Option B — Backend edge function (for accuracy + Swiss German support):
- Upload audio as multipart to `/functions/v1/process-transcription`
- The multipart builder is already stubbed in `TranscriptionService.swift`

**2. Implement mode processing**

- `ModeProcessor.process()` calls the same or a different edge function
- System prompts for all three modes are already defined in `ModeProcessor.ProcessingMode.systemPrompt`
- Fill in `transcription_provider` and `processing_provider` in `SessionLogger` once known

**3. Wire shortcut-to-DB sync in `SettingsViewModel`**

- `KeyboardShortcuts.shortcut(for: .dictatePrivate)` returns the current `Shortcut?`
- Convert to display string via `shortcut.description` (e.g. `"⌘⌥P"`)
- Write into `draft.shortcutPrivate` before calling `settingsService.saveSettings(_:session:)`
- Implement `syncShortcutsFromRecorder()` in `SettingsViewModel.swift`

---

## Dependencies

| Package | Purpose |
|---------|---------|
| [KeyboardShortcuts](https://github.com/sindresorhus/KeyboardShortcuts) | Global hotkey registration with system conflict detection |

All other functionality uses native Apple frameworks (AVFoundation, ApplicationServices, AppKit, SwiftUI, Security).
