# Voiceflow — Installation Guide (Beta)

## Installation

1. Open **Voiceflow-beta.dmg**
2. Drag **Voiceflow** → **Applications**
3. Eject the DMG

## First Launch

> **Important:** macOS Gatekeeper blocks apps that are not from the App Store on first open.
> This is a one-time step for beta builds.

**Option A — Right-click method (recommended):**
1. Open Finder → Applications
2. Right-click **Voiceflow** → **Open**
3. Click **Open** in the Gatekeeper dialog

**Option B — Terminal:**
```
xattr -cr /Applications/Voiceflow.app
```
Then double-click the app normally.

## Setup

1. **Log in** with your approved Voiceflow account

2. **Grant microphone access** — approve the system dialog on first launch

3. **Configure keyboard shortcuts**
   - Click the menu bar icon → **Settings**
   - Assign a shortcut to each mode (Private, Business, Calm)
   - Press **Save**

4. **Grant Accessibility access** (enables direct text insertion)
   - System Settings → Privacy & Security → Accessibility
   - Enable **Voiceflow**
   - Without this, transcribed text is pasted via clipboard

## How to Dictate

1. Focus any text field in any app
2. Press your configured shortcut — the menu bar icon turns **red** (recording active)
3. Speak your text
4. Press the **same shortcut again** — Voiceflow transcribes and inserts the text
5. The icon turns **green** when done

## Modes

| Mode | Shortcut | What it does |
|------|----------|--------------|
| **Private** | Your choice | Light cleanup — punctuation and capitalisation only |
| **Business** | Your choice | Professional rewrite, customer-facing tone |
| **Calm** | Your choice | De-escalated rewrite, removes aggressive language |

## Troubleshooting

**No menu bar icon:** The app may not have launched. Check Activity Monitor for "Voiceflow".

**Shortcut does nothing:** Open Settings and verify a shortcut is configured for the mode you're pressing.

**Text goes to clipboard instead of text field:** Accessibility permission is not granted.  
Go to System Settings → Privacy & Security → Accessibility → enable Voiceflow.

**App says "Account Pending":** Your account hasn't been approved yet. Contact your administrator.
