# Voiceflow Desktop — Changelog

All notable changes to the macOS app are recorded here. Format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/) and this project
adheres to [Semantic Versioning](https://semver.org/).

Generate a new section automatically with:

```sh
make release-notes                # append commits since last tag → [Unreleased]
make release-notes RELEASE=0.3.0  # roll [Unreleased] into [0.3.0] dated today
make release-notes RELEASE=0.3.0 TAG=1  # …and create git tag v0.3.0
```

---

## [Unreleased]

<!-- New entries since the last tagged release land here. -->

### Changed
- Sprint 2: auto-paste fix via CGEventPostToPid + Swiss language label cleanup (25d35e0)
- V1 completion: Whisper transcription, Gemini mode processing, recording UX, beta distribution (0bf97da)
- Complete desktop app: backend integration, full pipeline, schema audit, and distribution (3a92a2c)
- Initial commit (b5814e6)

### Fixed
- Fix Accessibility permission: show dialog once per build, live status in Settings (1c0afdb)
- Fix HTTP 401 on settings save: use live session reference + auto token refresh (f568c15)
- Fix: shortcuts wiped on every save, handler replaced with no-op (69d27eb)

---

## [0.2.0] — 2026-05-07

### Added
- **Custom V-with-wave app icon** rendered as Apple-style squircle (`AppIcon.icns`,
  built via `scripts/make-icon.sh` from `AppIcon.png` at the repo root).
- **Monochrome V-with-wave menu bar template** image extracted from the source PNG
  (`scripts/menubar-icon.py`) — adapts to Light/Dark mode automatically.
- **Localised language labels** in Settings: `Schweizer Hochdeutsch`,
  `Schweizerdeutsch (Dialekt)`, `Englisch`. Section headers and toggle copy in German.
- **Make targets**: `make icon` (builds .icns + menu bar variants),
  `make release-notes` (this file).

### Fixed
- **Auto-paste landing in the wrong app** — `simulatePasteKeystroke()` now captures
  the frontmost app's PID at the moment the user presses the stop-shortcut and uses
  `CGEvent.postToPid()` to deliver ⌘V directly to that process, even after several
  seconds of Whisper + Gemini processing changed focus. Paste delay 50 ms → 150 ms.
- **`transcription_sessions` insert silently failing with HTTP 400** — `JSONEncoder`
  was emitting `Date` fields as Swift reference-date doubles
  (`"started_at": 799835420.913518`); PostgREST rejected with
  `invalid input syntax for type timestamp with time zone`. Switched to
  ISO 8601 string encoding via a shared `JSONEncoder.supabase`.
- **Edge function 5xx no longer kills the pipeline** — when the Lovable edge
  function returns 500/502/503/504 (or 404), `ModeProcessor` now falls back to
  the raw Whisper transcript instead of surfacing "Processing Network error",
  so the user still gets text inserted during transient outages.
- **System Settings cached old/missing app icon** — full uninstall + `tccutil reset`
  + LaunchServices re-register procedure documented in the build pipeline.

### Diagnostics
- `NSLog` markers `[VF-Whisper]`, `[VF-API]`, `[VF-Paste]` surface HTTP error
  bodies, request URLs, target PID, and AX-trust state in the unified log
  (visible in Release builds — useful for support).

---

## [0.1.0] — 2026-04-21

Initial internal beta.

### Added
- Whisper transcription pipeline (OpenAI `whisper-1`, multipart upload).
- Three processing modes: Private / Business / Calm via Lovable Supabase edge
  function (`process-transcription`, Gemini Flash backend).
- Toggle-style global shortcuts via `KeyboardShortcuts` package.
- Output: AX direct insertion with clipboard + ⌘V fallback.
- Menu bar app (LSUIElement = true) with status panel popover.
- Settings window: shortcuts, language (auto/manual), output mode, mic device,
  permissions overview.
- Supabase backend integration: auth, profile (`status = 'active'` gate),
  user_settings (PATCH/POST), transcription_sessions logging, role lookup.
- Ad-hoc signed Release build via `make build-release` / `make dmg` / `make install`.
- DMG distribution with `INSTALL.md` first-launch guide.
