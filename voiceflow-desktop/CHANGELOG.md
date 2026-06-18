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

---

## [1.0.4] — 2026-06-18

### Fixed — the app answered the dictation instead of cleaning it up
- Regression from 1.0.3's prompt restructuring: when a dictation was phrased as
  a question ("wie spät ist es") or a command ("mach mir eine Liste"), the model
  treated it as a message to it and **answered/executed it** instead of just
  tidying the text — in all three modes.
- Fix: the dictated text is now passed to the model wrapped in explicit
  `<<<DICTATION>>> … <<<END>>>` delimiters, and the prompt's absolute rules state
  that this block is raw content to rewrite, never a question/command addressed
  to the model. Verified across question-, command- and statement-style inputs
  in all modes; dialect output (1.0.3) still works.
- The Predicted-Outputs speed hint now uses the raw dictation, not the wrapped
  message, so the latency optimisation is unaffected.

---

## [1.0.3] — 2026-06-18

### Fixed — custom instructions could not change the output language/dialect
- A custom instruction asking for spoken Swiss-German dialect (Mundart) was
  silently overridden: the built-in prompt had a hard "always output Swiss
  Standard German (Hochdeutsch), never output dialect spelling" rule marked as
  a non-overridable universal rule — and the user's instruction was explicitly
  told it "never overrides the universal rules". The two contradicted each
  other, so dialect output was intermittent.
- The prompt is restructured by precedence: exactly **one** absolute rule
  (output only the transformed text — the app inserts it directly), then the
  **user's custom instruction**, then the **default style** (incl. the
  Swiss-Standard-German default) which now applies only where the instruction
  is silent. A custom instruction can now reliably change the output language
  or request spoken dialect, and the default still gives clean Hochdeutsch when
  no instruction is set.

### Note for dialect output
- For authentic spoken dialect, the **gpt-4o** text model writes noticeably
  better Swiss-German than gpt-4o-mini. Switch it under
  Settings → Modelle → Text-Veredelung. (No code change — already selectable.)

---

## [1.0.2] — 2026-06-18

### Fixed — performance / occasional long hangs
- **Requests no longer hang for up to 45–120 s on a flaky connection.**
  Diagnosis: the OpenAI API itself is fast (transcription + rewrite measure
  ~1.4–1.8 s end-to-end). The slowness was a stalled connection waiting on the
  old generous timeouts before failing. The unified log showed connections
  hanging 165 s and 213 s.
  - `timeoutIntervalForRequest` 45 s → **20 s**, `timeoutIntervalForResource`
    120 s → **40 s**, plus an explicit 20 s timeout on each transcription/chat
    request. A healthy request returns in <2 s, so 20 s of silence means a dead
    connection — fail fast and retry on a fresh one instead of hanging.
  - `waitsForConnectivity = false`: fail immediately when offline rather than
    waiting.
  - Retry countdown shortened 5 s → **2 s** in both pipeline stages, since a
    stalled request is best retried quickly on a fresh connection.
- **Long recordings stay fast.** The connection warmed at record-start gets
  closed by the server after ~60–90 s idle; the transcription POST after a long
  dictation then hit a dead connection and stalled. The app now re-warms the
  connection every 25 s during recording, so it's always fresh at upload time.

Net effect: worst-case recovery from a network blip drops from ~95 s+ to ~24 s,
and a healthy dictation is unchanged at ~2 s.

---

## [1.0.1] — 2026-06-10

### Fixed
- **Recordings could still be lost when the transcription stage failed.** The
  rewrite stage had retry + fallback since 0.2.x, but a timeout/429/5xx on the
  transcription call threw straight to the error state and the audio file was
  deleted. The transcription stage now retries once with the same visible
  5-second countdown.
- **Failed recordings are rescued, never deleted.** If the pipeline still fails
  after retries, the audio file is moved to
  `~/Library/Application Support/Voiceflow/Rescue/` (capped at the 5 most
  recent) and the status panel shows a "Gerettete Aufnahme … Erneut versuchen"
  row — which survives an app restart. Retrying re-runs the full pipeline and
  delivers the result to the clipboard (the original cursor position is gone by
  then). The error state now says "Aufnahme gerettet" instead of silently
  discarding your words.

### Performance
- OpenAI Predicted Outputs on the rewrite step (~25–40 % lower latency for
  Privat/Business; benchmarked 1.40 s → 1.03 s on a real dictation).

---

## [1.0.0] — 2026-06-10

**First stable release.** Functionally identical to 0.4.0 — this release marks
the app as ready to hand to other people.

### Added
- English README and INSTALL.md aimed at end users receiving the DMG,
  including the one-time Keychain "Always Allow" step and the Gatekeeper
  right-click → Open flow.
- DMG artifact is now versioned (`Voiceflow-1.0.0.dmg`).

### Notes for testers
- The build is ad-hoc signed: first launch requires right-click → Open, and
  the Keychain prompt appears once — click "Always Allow".
- No auto-update yet; new versions ship via the GitHub Releases page.

---

## [0.4.0] — 2026-06-10

### Changed (modes)
- **Three modes: Privat, Business, Random** (Calm replaced by Random). Random
  is the free mode: its behaviour is defined by your own instruction — e.g.
  "Übersetze alles auf Englisch" or "Formatiere als Bullet-Liste".
- **Per-mode custom instructions**: every mode has a free-text instruction
  field in Settings that personalises the AI output for that mode. The
  instruction is appended to the system prompt on every dictation.
- Existing Calm shortcut bindings are migrated to Random automatically.

### Added
- **Model selection with guidance** in Settings:
  - Transkription: GPT-4o mini Transcribe (empfohlen — am schnellsten/günstigsten),
    GPT-4o Transcribe (höchste Genauigkeit), Whisper (98 Sprachen).
  - Text-Veredelung: GPT-4o mini (empfohlen) oder GPT-4o (beste Schreibqualität).
  - Each picker shows a plain-language hint about speed, price, accuracy and
    language coverage; a footer explains which model suits which languages.
- **Trace-free uninstall** (Settings → Daten & Deinstallation): removes the
  API key from the Keychain, all preferences and shortcut bindings, the local
  history, the login item, mic/accessibility permissions (tccutil), and moves
  the app to the Trash — with a confirmation dialog listing everything.
- **History controls**: toggle "Diktat-Verlauf lokal speichern" (default on)
  and a one-click "Verlauf löschen".

### Performance
- **Connection warm-up**: when recording starts, the TLS handshake to
  api.openai.com runs in parallel — the transcription POST reuses the warm
  connection, saving ~300–600 ms on every dictation.
- **Speech-optimised recording**: 16 kHz mono AAC @ 32 kbps (ASR models
  downsample to 16 kHz anyway) — roughly halves the upload size vs 44.1 kHz.
- Timing logs for both pipeline stages: `[VF-Transcribe]` and `[VF-Chat]`.

### Security (audit findings)
- The API key lives in the Keychain (AfterFirstUnlock, ThisDeviceOnly), is
  only ever sent to https://api.openai.com, and never appears in logs.
- TLS 1.2 minimum enforced on the URLSession.
- Entitlements documented: network.client is exclusively for api.openai.com;
  disable-library-validation is required only while ad-hoc signed.
- History is plain-text local JSONL — now user-controllable (toggle + delete
  + full uninstall).

### Fixed
- **Menu bar icon showed a checkerboard frame** — the template was extracted
  from the raw source PNG whose baked-in fake-transparency checker passed the
  luminance threshold. Extraction now runs on the squircle-masked icon and
  uses graded alpha for smooth edges at 18 px.

---

## [0.3.0] — 2026-06-10

**The "Fable" release: fully local-first. Bring your own OpenAI key — no login,
no app backend, nothing between you and OpenAI.**

### Changed (architecture)
- **Supabase/Lovable backend removed entirely.** No more login, profiles,
  server-side settings, or edge-function processing. Deleted: `AuthService`,
  `LoginView`/`LoginViewModel`, `APIClient`, `Endpoints`, `BackendSchema`,
  `UserProfile`, `TranscriptionSession`, `SessionLogger`.
- **Setup is now a single step**: paste your OpenAI API key. The key is validated
  against `/v1/models` and stored in the macOS Keychain (this device only) —
  inspired by the bring-your-own-key model of tools like MacWhisper.
- **Tone-of-voice prompts now live in the app** (`ProcessingMode.systemPrompt`)
  and run via OpenAI chat completions (`gpt-4o-mini`). Swiss rules built in:
  Swiss Standard German output (ss statt ß) for German/dialect input, English
  for English input, Du/Sie mirrored from the transcript, self-corrections
  applied, filler words removed, no letter structure ever added.
- **Settings stored locally** (UserDefaults) — saving is instant, no 401s, no
  token refresh, works offline.

### Added
- **Faster transcription**: `gpt-4o-mini-transcribe` (half the price of
  whisper-1, lower latency, better word error rate) with automatic, permanent
  fallback to `whisper-1` for accounts without access to the new model.
- **Onboarding window** on first launch: paste key → validate → go. Includes a
  link to create a key and a cost estimate (~0.3 Rappen/Minute).
- **API key section in Settings**: masked display, validate & replace, remove.
- **Local dictation history** (`~/Library/Application Support/Voiceflow/history.jsonl`),
  one JSON line per dictation. Right-click menu → "Verlauf öffnen" reveals it in Finder.
- **Last dictation in the status panel** with a copy button — recover any result
  without re-dictating.
- New menu bar state `needsAPIKey` (orange key icon) with a CTA into Settings.
- UI language: German throughout (matches the app's audience).

### Fixed
- The chronic "Processing Network error" outages are gone by construction — the
  flaky Lovable edge function no longer exists in the pipeline. Retry + raw-text
  fallback retained for OpenAI itself (429/5xx/timeouts).

---

## [0.2.1] — 2026-05-07

### Added
- **App version visible in the UI** so users (and bug reports) can identify the
  exact build they run. Shown in the Settings footer (with a tooltip prompting
  users to include it in bug reports) and in the status panel header next to
  the Voiceflow title. New `AppInfo` enum reads `CFBundleShortVersionString`
  + `CFBundleVersion` and exposes a `v0.2.1 (4)` display string.

### Fixed
- **Recordings lost on connection timeout** — the v0.2.0 retry loop only matched
  `APIError` (HTTP-level errors). When the edge function hung for 74 s and the
  socket timed out, the resulting `URLError` bypassed retry entirely and the
  audio was discarded. `ModeProcessor.isRetryable` now also classifies
  `URLError.{timedOut, cannotFindHost, cannotConnectToHost,
  networkConnectionLost, notConnectedToInternet, dnsLookupFailed,
  secureConnectionFailed, badServerResponse, ...}` as retryable, alongside any
  `ProcessingError` raised from a server-returned `{"error": "…"}` body.
- The retry catch is now a generic `catch` (instead of `catch let apiError as APIError`),
  so unexpected error types fall back to the raw Whisper transcript instead of
  surfacing a user-visible "Error: …" and dropping the audio.

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
