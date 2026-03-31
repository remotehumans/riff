# Riff

Monorepo for hands-free AI interaction — smart ring input and voice narrator.

## Components

### riff-bridge
macOS daemon that bridges a JX-11 smart ring (BLE HID) to keyboard events for hands-free voice interaction.
- **Tap**: Toggle Left Option key (voice-to-text push-to-talk)
- **Swipe right**: Enter key (submit messages)
- **Swipe left**: Backspace/Delete

Uses IOKit HID Manager for device-specific detection (VendorID/ProductID) and CGEvent tap to block default media key behavior.

### riff-voice
Voice narrator daemon that speaks AI agent output aloud using MLX-Audio Kokoro TTS.
- **FIFO queue**: Multiple sessions send text, one voice at a time
- **Per-agent voices**: 54 Kokoro presets mapped by project directory
- **Session announcements**: "project-name says:" before each message
- **Interrupt support**: Stop speech instantly via `riff-ctl interrupt` or ring Escape button
- **Speed control**: Adjustable playback speed (0.5-3.0x) via `riff-ctl speed`

Socket protocol over `/tmp/riff.sock`. Claude Code Stop hook auto-sends summaries.

## Build & Run

### riff-bridge
```bash
cd riff-bridge
swiftc riff_bridge.swift -o riff-bridge -framework CoreGraphics -framework IOKit
./riff-bridge
```

Requires macOS Accessibility permission. Signed with Apple Development certificate for stable permissions across recompiles.

LaunchAgent: `~/Library/LaunchAgents/co.remotehumans.riff-bridge.plist`

### riff-voice
```bash
cd riff-voice
make install    # uv sync + LaunchAgent + CLI symlinks + hook
riff-say "hello"
riff-ctl status
```

LaunchAgent: `~/Library/LaunchAgents/co.remotehumans.riff-voice.plist`
