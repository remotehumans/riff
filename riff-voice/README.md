# Riff Voice - Voice Narrator for AI Agents

Riff Voice gives your AI agents a voice. It runs a local daemon that listens on a Unix socket for text-to-speech requests and speaks them aloud using Kokoro TTS via MLX on Apple Silicon. Claude Code and Codex completion hooks trigger narration automatically when an agent finishes work or hits errors - so you can walk away from your desk and still know what's happening.

## How It Works

- **riff-daemon** runs as a macOS LaunchAgent, listening on a Unix socket at `/tmp/riff.sock`
- **riff-say** sends text to the daemon for immediate speech synthesis and playback
- **riff-ctl** controls the daemon (enable, disable, interrupt, list voices, adjust speed)
- **Claude Code and Codex hooks** send completed agent replies to Riff

Kokoro TTS runs entirely on-device using MLX (Apple Neural Engine) - no API keys, no network, no latency.

## Quick Start

```bash
cd riff-voice
make install
```

This installs dependencies, sets up the LaunchAgent, creates CLI symlinks, and copies the Claude Code hook.

## Codex Setup

Codex exposes an official `agent-turn-complete` notification containing the final assistant message. Point Codex's user-level `notify` setting at Riff's adapter:

```toml
notify = ["/absolute/path/to/riff/riff-voice/riff-codex-notify.sh"]
```

Then make the adapter executable:

```bash
chmod +x riff-codex-notify.sh
```

The adapter also forwards the notification to Codex Computer Use when it is installed, preserving remote-control turn completion. Codex threads receive their own Riff session IDs, names, and automatically assigned voices.

## CLI Usage

```bash
# Speak some text
riff-say "Build complete, all tests passing"

# Speak with a specific voice
riff-say --voice af_heart "Starting the deployment now"

# Control the daemon
riff-ctl status          # Check daemon state
riff-ctl disable         # Mute narration
riff-ctl enable          # Unmute narration
riff-ctl voices          # List available voices
riff-ctl speed 1.3       # Adjust speech rate
```

## Configuration

Config lives at `~/.config/riff/config.json` (created on first `make install` from `config.default.json`).

Key settings:
- `default_voice` - default Kokoro voice ID (e.g. `af_heart`)
- `announcer_voice` - voice used for session-name announcements
- `speed` - speech rate multiplier
- `socket_path` - Unix socket path (default `/tmp/riff.sock`)

## Voice Presets

Riff currently exposes 27 American and British Kokoro voices. Voice IDs follow the pattern `{language}_{name}` - e.g. `af_heart`, `am_puck`, `bf_emma`. Run `riff-ctl voices` to list available voices.

## Files

| File | What it does |
|---|---|
| `src/riff/` | Python package (daemon, CLI, TTS engine) |
| `riff-hook.sh` | Claude Code hook for completion narration |
| `riff-hook-processor.py` | Shared Claude/Codex payload processor |
| `riff-codex-notify.sh` | Codex completion adapter and notification dispatcher |
| `config.default.json` | Default configuration template |
| `co.remotehumans.riff-voice.plist` | LaunchAgent config (auto-start on login) |
| `Makefile` | Install, uninstall, and management commands |
| `pyproject.toml` | UV project config and dependencies |
