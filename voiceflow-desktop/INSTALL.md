# Voiceflow — Installation Guide

Voiceflow is a macOS menu bar app for system-wide dictation with AI cleanup.
You bring your own OpenAI API key — there is no account, no login, and no
backend in between. Your key and your dictation history never leave your Mac.

## Requirements

- macOS 13 (Ventura) or newer
- An OpenAI API key (created in step 3 — takes one minute)

## Install

1. **Open `Voiceflow-x.y.z.dmg`** and drag **Voiceflow** into **Applications**.

2. **First launch:** right-click `Voiceflow.app` → **Open** → confirm **Open**
   in the dialog. This one-time step is required because beta builds are not
   notarized by Apple.
   Alternative via Terminal: `xattr -cr /Applications/Voiceflow.app`

3. **Enter your OpenAI API key:** the setup window opens automatically on
   first launch. Create a key at https://platform.openai.com/api-keys, paste
   it, done. The key is stored in this Mac's Keychain only.
   Typical cost: about $0.003 per minute of dictation.

4. **Set your shortcuts:** click the menu bar icon → **Einstellungen** → record
   a shortcut for each mode (e.g. ⌥1, ⌥2, ⌥3). Changes save automatically.

5. **Grant Microphone access** when macOS asks during your first dictation.

6. **Grant Accessibility access** (recommended — enables direct text
   insertion): System Settings → Privacy & Security → Accessibility → enable
   Voiceflow. Without it, text lands in the clipboard and you paste with ⌘V.

7. **Keychain prompt (one time):** at your first dictation macOS may ask
   "Voiceflow wants to use your confidential information…". Click
   **Always Allow** — this authorizes this app build to read its own API key
   and will not appear again.

## Usage

- Press a shortcut → speak → press the same shortcut again.
- The polished text appears in your active text field, in the tone of the mode:
  - **Privat** — light cleanup, your wording stays
  - **Business** — polished, professional register
  - **Random** — your rules: give it any instruction in Settings
    (e.g. "Translate everything to English")
- Each mode accepts a custom instruction in Settings to personalize the output.
- History: right-click the menu bar icon → **Verlauf öffnen** (stored locally,
  can be disabled or deleted in Settings).
- Remove the app completely (key, settings, history, permissions, app):
  Settings → **Daten & Deinstallation** → **App vollständig entfernen**.

## Support

Please include the version number (bottom-left in Settings, e.g. `v1.0.0 (8)`)
when reporting issues.
