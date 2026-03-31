# Riff Setup Reference

## Overview

Riff has two independent components. Either can be installed alone or both together.

- **Riff Bridge** (`riff-bridge/`) - macOS daemon that maps a JX-11 Bluetooth smart ring's gestures to keyboard events, enabling hands-free voice interaction with any app
- **Riff Voice** (`riff-voice/`) - macOS daemon that speaks AI agent output aloud using on-device Kokoro TTS via MLX on Apple Silicon

## Prerequisites

### Riff Bridge
- macOS (tested on macOS 15 Sequoia, works on Intel and Apple Silicon)
- Xcode Command Line Tools (for `swiftc` compiler)
- JX-11 smart ring paired via Bluetooth
- A voice-to-text app with a configurable keyboard shortcut (e.g. FluidVoice, Superwhisper, Whisper Flow, Handy)
- Apple Developer certificate (free Apple ID works for personal signing)

### Riff Voice
- macOS with Apple Silicon (M1 or later) - required for MLX
- Python 3.10+
- UV package manager (`brew install uv` or `curl -LsSf https://astral.sh/uv/install.sh | sh`)

## Riff Bridge Setup

### Step 1: Check prerequisites

```bash
# Verify Swift compiler
swiftc --version

# If missing, install Xcode Command Line Tools
xcode-select --install
```

### Step 2: Pair the JX-11 ring

1. Put ring in pairing mode (hold button until LED flashes)
2. Open System Settings > Bluetooth
3. Connect to "JX-11"
4. Verify it appears in paired devices

### Step 3: Build and install

```bash
cd riff-bridge
make all      # Compiles Swift code and signs binary
make install  # Sets up LaunchAgent for auto-start
```

If code signing fails (no Apple Developer certificate), the binary still works but Accessibility permissions may reset on recompile. To fix:
```bash
# Sign with ad-hoc identity (no certificate needed)
codesign --sign - --options runtime riff-bridge
```

### Step 4: Grant macOS permissions

Two permissions are required. The system will prompt on first run, or add manually:

1. **System Settings > Privacy & Security > Input Monitoring** - add `riff-bridge` binary
2. **System Settings > Privacy & Security > Accessibility** - add `riff-bridge` binary

### Step 5: Verify

```bash
tail -f /tmp/riff-bridge.log
```

Expected output: "Ring connected" followed by HID usage listings.

### Default key mappings

| Ring gesture | Key sent | Purpose |
|---|---|---|
| Tap (button press) | Option (hold/release toggle) | Push-to-talk for voice-to-text |
| Swipe right | Enter | Submit/send |
| Swipe left | Backspace | Delete |
| Scroll (Y-axis) | Scroll events | Scroll screen |
| Bottom button (short touch) | Escape | Interrupt |

### Customising key mappings

All mappings are in `riff_bridge.swift`. The key constants to change:

```swift
// macOS virtual keycodes - change these to remap gestures
let kKeyCodeOption: CGKeyCode = 58   // Tap gesture
let kKeyCodeReturn: CGKeyCode = 36   // Right swipe
let kKeyCodeDelete: CGKeyCode = 51   // Left swipe
let kKeyCodeEscape: CGKeyCode = 53   // Bottom button
```

Common macOS virtual keycodes:
- Command: 55, Shift: 56, Option: 58, Control: 59
- Space: 49, Tab: 48, Return: 36, Escape: 53
- Arrow keys: Left=123, Right=124, Down=125, Up=126

After changing mappings, rebuild and reinstall:
```bash
make all && make install
```

### Matching voice-to-text app shortcut

The tap gesture sends Option key by default. Configure the voice-to-text app to use the same key as its push-to-talk trigger:

- **FluidVoice**: Settings > Keyboard Shortcut > set to Option
- **Superwhisper**: Settings > Shortcut > set to match
- **Other apps**: Find the push-to-talk / dictation shortcut setting and match it

If the app uses a different shortcut (e.g. Cmd+Shift+A), change `kKeyCodeOption` in the Swift source to match, or change the app's shortcut to Option.

## Riff Voice Setup

### Step 1: Check prerequisites

```bash
# Verify Apple Silicon
uname -m  # Should output "arm64"

# Verify Python
python3 --version  # Needs 3.10+

# Verify UV
uv --version

# If UV missing
brew install uv
# or
curl -LsSf https://astral.sh/uv/install.sh | sh
```

### Step 2: Install

```bash
cd riff-voice
make install
```

This runs `uv sync` to install Python dependencies (including MLX and Kokoro TTS), sets up the LaunchAgent, creates CLI symlinks (`riff-say` and `riff-ctl` in `~/.local/bin`), and copies the Claude Code hook.

First run downloads the Kokoro model (~165MB). This happens automatically.

### Step 3: Verify

```bash
# Check daemon is running
riff-ctl status

# Test speech
riff-say "Riff Voice is working"

# If riff-say not found, add ~/.local/bin to PATH
export PATH="$HOME/.local/bin:$PATH"
# Add to shell profile for persistence:
echo 'export PATH="$HOME/.local/bin:$PATH"' >> ~/.zshrc
```

### Step 4: Configure (optional)

Config file: `~/.config/riff/config.json`

```json
{
  "enabled": true,
  "model": "mlx-community/Kokoro-82M-bf16",
  "default_voice": "am_adam",
  "announcer_voice": "af_heart",
  "speed": 1.5,
  "voice_map": {},
  "socket_path": "/tmp/riff.sock",
  "announce_sessions": true
}
```

Key settings:
- `default_voice` - Kokoro voice ID (run `riff-ctl voices` to list all 54 options)
- `speed` - Speech rate multiplier (1.0 = normal, 1.5 = faster)
- `voice_map` - Map project directories to specific voices (e.g. `{"/path/to/project": "af_sky"}`)
- `announce_sessions` - Whether to announce which project is speaking

### Claude Code integration

The `make install` command copies `riff-hook.sh` to `~/.claude/hooks/`. To activate it, add a Stop hook in Claude Code settings:

```json
{
  "hooks": {
    "Stop": [
      {
        "matcher": "",
        "hooks": ["~/.claude/hooks/riff-hook.sh"]
      }
    ]
  }
}
```

This makes Claude Code automatically narrate summaries when it finishes work.

## Troubleshooting

### Riff Bridge

| Problem | Solution |
|---|---|
| Ring not detected | Re-pair in Bluetooth settings. Check `tail -f /tmp/riff-bridge.log` |
| Keys not registering | Grant Input Monitoring + Accessibility permissions in System Settings |
| Bridge not starting on login | Run `make install` to reinstall LaunchAgent |
| "Signing failed" during build | Run `security unlock-keychain` or use ad-hoc signing: `codesign --sign - --options runtime riff-bridge` |
| Scroll not working in terminal | Enable tmux mouse mode: `set -g mouse on` in `.tmux.conf` |
| Volume/mute keys still firing | The daemon may not be running - check with `launchctl list | grep riff-bridge` |

### Riff Voice

| Problem | Solution |
|---|---|
| `riff-say` command not found | Add `~/.local/bin` to PATH, or run directly: `./riff-voice/.venv/bin/riff-say` |
| No audio output | Check `riff-ctl status`, verify daemon is running. Check `/tmp/riff.log` |
| Model download fails | Check internet connection. Model downloads on first use from HuggingFace |
| "No module named mlx" | Apple Silicon required. MLX does not work on Intel Macs |
| High CPU on first run | Normal - model compilation happens once on first speech request |
| Daemon won't start | Check `/tmp/riff.log` for errors. Try `make restart` |

### Both components

To check if LaunchAgents are running:
```bash
launchctl list | grep riff
```

To restart a component:
```bash
# Riff Bridge
cd riff-bridge && make install

# Riff Voice
cd riff-voice && make restart
```

To uninstall:
```bash
# Riff Bridge
cd riff-bridge
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/co.remotehumans.riff-bridge.plist

# Riff Voice
cd riff-voice && make uninstall
```
