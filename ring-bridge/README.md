# JX-11 Smart Ring Bridge

A macOS daemon that turns a cheap Bluetooth smart ring into a wireless controller for AI coding agents.

## What This Does

This lets you walk around your house, co-working space, or anywhere within Bluetooth range of your Mac and control AI coding agents like [Claude Code](https://claude.com/claude-code) and [Codex](https://openai.com/codex) using just your voice and a smart ring on your finger.

Pair the ring with a wireless microphone (like a DJI wireless mic) and you can brainstorm, build systems, create workflows, and do project work without being at your desk or keyboard.

**The ring gives you five controls:**

| Ring action | What it does | Why you need it |
|---|---|---|
| **Tap** (press button) | Toggle voice recording on/off | Start and stop talking to your AI agent |
| **Right arrow** | Send (Enter key) | Submit what you said to the agent |
| **Left arrow** | Delete (Backspace key) | Remove what you just said if you misspoke |
| **Scroll up/down** (touchpad) | Scroll the screen | Read through agent output and code |
| **Bottom button** | Escape key | Interrupt the agent if it goes off track |

## How It Works

The ring pretends to be a media controller (like headphone buttons). This daemon catches those signals before macOS turns them into volume/mute commands, and translates them into keyboard actions that coding agents understand.

The voice recording toggle holds down the Option key, which apps like [Superwhisper](https://superwhisper.com/) use as a push-to-talk trigger. When you tap the ring, it starts recording. Tap again, it stops. Then press the right arrow to send your message.

## Hardware

- **Smart ring**: JX-11 Bluetooth ring (available on AliExpress/Amazon for ~$15)
- **Wireless mic**: Any wireless microphone that connects to your Mac (DJI Mic, Rode Wireless Go, etc.)
- **Computer**: Mac running macOS (tested on macOS 15 Sequoia)

## Setup

### 1. Pair the ring

Put the JX-11 ring in pairing mode and connect it via Mac Bluetooth settings. It shows up as "JX-11".

### 2. Build the bridge

```bash
cd ring-bridge
make all
```

This compiles the Swift code and signs it with your Apple Developer certificate.

### 3. Grant permissions

The bridge needs two macOS permissions:

- **Input Monitoring** - to read the ring's button presses
- **Accessibility** - to send keyboard events to other apps

Go to System Settings > Privacy & Security and add the `jx11-bridge` binary to both lists.

### 4. Install as a background service

```bash
make install
```

This copies the binary and sets up a LaunchAgent so the bridge starts automatically when you log in and restarts if it crashes.

### 5. Check it's running

```bash
tail -f /tmp/jx11-bridge.log
```

You should see "Ring connected" and a list of available controls.

## Workflow

1. Put on the ring and clip on your wireless mic
2. Open Claude Code, Codex, or any terminal-based AI agent
3. Walk away from your desk
4. **Tap the ring** to start recording your voice
5. Speak your instructions ("Create a new API endpoint for user profiles...")
6. **Tap again** to stop recording
7. **Press the right arrow** to send it to the agent
8. **Scroll the touchpad up/down** to read the agent's response
9. **Press the bottom button** if you need to interrupt the agent
10. **Press the left arrow** if you need to delete and start over

## Troubleshooting

**Ring not detected**: Make sure it's paired in Bluetooth settings and shows as "JX-11".

**Keys not working**: Check Input Monitoring and Accessibility permissions in System Settings > Privacy & Security.

**Bridge not starting**: Run `tail -f /tmp/jx11-bridge.log` to see error messages.

**Scroll not working in terminal**: Make sure tmux has mouse mode enabled (`set -g mouse on` in your `.tmux.conf`).

## Files

| File | What it does |
|---|---|
| `jx11_bridge.swift` | The main daemon code |
| `Makefile` | Build, sign, and install commands |
| `co.remotehumans.jx11-bridge.plist` | LaunchAgent config (auto-start on login) |

## Tech Details

- Written in Swift, no external dependencies
- Uses IOKit HID Manager to read ring input (matched by VendorID/ProductID)
- Uses CGEvent tap to block default media key behaviour
- Timing correlation between IOKit and CGEvent callbacks prevents the ring's default volume/mute actions
- Continuous scroll events during Y-axis swipes for smooth scrolling
- Runs as a macOS LaunchAgent with KeepAlive for automatic restart
