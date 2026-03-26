# Riff - Voice Narrator for AI Agents

Riff gives your AI coding agents a voice. It runs a local daemon that listens on a Unix socket for text-to-speech requests and speaks them aloud using Kokoro TTS via MLX on Apple Silicon. Claude Code hooks trigger narration automatically when your agent starts tasks, finishes work, or hits errors - so you can walk away from your desk and still know what's happening.

## How It Works

- **riff-daemon** runs as a macOS LaunchAgent, listening on a Unix socket at `/tmp/riff.sock`
- **riff-say** sends text to the daemon for immediate speech synthesis and playback
- **riff-ctl** controls the daemon (pause, resume, change voice, adjust volume)
- **Claude Code hooks** call `riff-say` on agent lifecycle events (notification, task start/end, errors)

Kokoro TTS runs entirely on-device using MLX (Apple Neural Engine) - no API keys, no network, no latency.

## Quick Start

```bash
cd riff
make install
```

This installs dependencies, sets up the LaunchAgent, creates CLI symlinks, and copies the Claude Code hook.

## CLI Usage

```bash
# Speak some text
riff-say "Build complete, all tests passing"

# Speak with a specific voice
riff-say --voice af_heart "Starting the deployment now"

# Control the daemon
riff-ctl status          # Check daemon state
riff-ctl pause           # Mute narration
riff-ctl resume          # Unmute narration
riff-ctl voice af_sky    # Switch voice
riff-ctl volume 0.7      # Set volume (0.0-1.0)
```

## Configuration

Config lives at `~/.config/riff/config.json` (created on first `make install` from `config.default.json`).

Key settings:
- `voice` - default Kokoro voice ID (e.g. `af_heart`)
- `volume` - playback volume, 0.0 to 1.0
- `speed` - speech rate multiplier
- `socket_path` - Unix socket path (default `/tmp/riff.sock`)

## Voice Presets

Riff ships with access to all 54 Kokoro voices. Voice IDs follow the pattern `{language}_{name}` - e.g. `af_heart`, `am_fenrir`, `bf_emma`. Run `riff-ctl voices` to list available voices.

## Files

| File | What it does |
|---|---|
| `src/riff/` | Python package (daemon, CLI, TTS engine) |
| `hooks/riff-hook.sh` | Claude Code hook for agent lifecycle narration |
| `config.default.json` | Default configuration template |
| `co.remotehumans.riff.plist` | LaunchAgent config (auto-start on login) |
| `Makefile` | Install, uninstall, and management commands |
| `pyproject.toml` | UV project config and dependencies |
