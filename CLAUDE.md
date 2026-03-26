# Voice AI

Monorepo for voice AI components — smart ring input, transcription, and voice-driven workflows.

## Components

### ring-bridge
macOS daemon that bridges a JX-11 smart ring (BLE HID) to keyboard events for voice AI interaction.
- **Tap**: Toggle Left Option key (FluidVoice push-to-talk)
- **Swipe right**: Enter key (submit messages)
- **Swipe left**: Backspace/Delete

Uses IOKit HID Manager for device-specific detection (VendorID/ProductID) and CGEvent tap to block default media key behavior.

### riff
Voice narrator daemon that speaks AI agent output aloud using MLX-Audio Kokoro TTS.
- **FIFO queue**: Multiple sessions send text, one voice at a time
- **Per-agent voices**: 54 Kokoro presets mapped by project directory
- **Session announcements**: "project-name says:" before each message
- **Interrupt support**: Stop speech instantly via `riff-ctl interrupt` or ring Escape button
- **Speed control**: Adjustable playback speed (0.5-3.0x) via `riff-ctl speed`

Socket protocol over `/tmp/riff.sock`. Claude Code Stop hook auto-sends summaries.

## Build & Run

### ring-bridge
```bash
cd ring-bridge
swiftc jx11_bridge.swift -o jx11-bridge -framework CoreGraphics -framework IOKit
./jx11-bridge
```

Requires macOS Accessibility permission. Signed with Apple Development certificate for stable permissions across recompiles.

LaunchAgent: `~/Library/LaunchAgents/co.remotehumans.jx11-bridge.plist`

### riff
```bash
cd riff
make install    # uv sync + LaunchAgent + CLI symlinks + hook
riff-say "hello"
riff-ctl status
```

LaunchAgent: `~/Library/LaunchAgents/co.remotehumans.riff.plist`
