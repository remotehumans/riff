---
name: riff-setup
description: This skill should be used when setting up Riff - the hands-free voice AI system with a smart ring controller (Riff Bridge) and voice narrator (Riff Voice). Triggers include "set up riff", "install riff", "configure riff", "set up the ring", "set up voice", "riff bridge", "riff voice", or any request to install or configure the Riff components.
---

# Riff Setup

Set up Riff for hands-free interaction with AI agents and apps. Riff has two independent components that can be installed separately or together:

- **Riff Bridge** - Maps a JX-11 Bluetooth smart ring to keyboard events (voice recording toggle, send, delete, scroll, interrupt)
- **Riff Voice** - Speaks AI agent output aloud using on-device TTS (Kokoro via MLX on Apple Silicon)

## Setup Workflow

### 1. Determine which components to install

Ask the user which components they want:

- **Riff Bridge only** - Control AI agents or any app by voice using the smart ring. Read output on screen.
- **Riff Voice only** - Type normally at the desk. Hear AI agent output spoken aloud.
- **Both** - Full hands-free loop: speak via ring, hear responses via Riff Voice.

If unclear, recommend starting with **Riff Bridge** - it's the core hands-free experience.

### 2. Check prerequisites

Read `references/setup-guide.md` for the full prerequisite checklist per component. Verify each prerequisite before proceeding. Key checks:

**Riff Bridge**: Verify `swiftc --version` works, confirm JX-11 ring is paired in Bluetooth settings, confirm user has a voice-to-text app installed.

**Riff Voice**: Verify `uname -m` returns `arm64` (Apple Silicon required), verify Python 3.10+, verify `uv` is installed.

### 3. Install the selected components

Follow the step-by-step installation in `references/setup-guide.md`. Run the commands and verify each step before proceeding to the next.

For Riff Bridge:
```bash
cd riff-bridge
make all && make install
```
Then guide the user through granting Input Monitoring and Accessibility permissions.

For Riff Voice:
```bash
cd riff-voice
make install
```
Then verify with `riff-say "Riff Voice is working"`.

### 4. Configure key mappings (Riff Bridge)

After installation, ask the user:
- Which voice-to-text app they use
- What keyboard shortcut their app uses for push-to-talk

If their app's shortcut differs from Option key (the default), modify `riff_bridge.swift` to match. See `references/setup-guide.md` for the constants to change and common macOS virtual keycodes.

After any changes: `make all && make install`

### 5. Configure voice settings (Riff Voice)

After installation, optionally customise `~/.config/riff/config.json`:
- Default voice (run `riff-ctl voices` to list options)
- Speech speed
- Per-project voice mapping

For Claude Code integration, set up the Stop hook as documented in `references/setup-guide.md`.

### 6. Verify the full setup

**Riff Bridge**: Have the user tap the ring and confirm their voice-to-text app activates. Then swipe right to confirm Enter key works.

**Riff Voice**: Run `riff-say "Setup complete"` and confirm audio plays.

**Both**: Have the user tap the ring, speak a message, send it, and hear a response narrated back.

## Troubleshooting

Consult the troubleshooting tables in `references/setup-guide.md` for common issues with each component. Check `/tmp/riff-bridge.log` and `/tmp/riff.log` for error details.
