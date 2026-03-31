# Riff Bridge - Smart Ring Controller

![Voice AI Workflow - Walk around, think out loud, build with AI](voice-ai-workflow-nb.jpg)

A macOS daemon that turns a cheap Bluetooth smart ring into a wireless controller for AI agents and any app that accepts text input.

## What This Does

This lets you walk around your house, co-working space, or anywhere within Bluetooth range of your Mac and speak to your computer using just your voice and a smart ring on your finger.

Pair the ring with a wireless microphone (like a DJI wireless mic) and you can talk to AI agents like [Claude Code](https://claude.com/claude-code) and [Codex](https://openai.com/codex), dictate notes, write emails, or put text into any application - all without being at your desk or keyboard.

**The default ring controls:**

| Ring action | Default mapping | Why you need it |
|---|---|---|
| **Tap** (press button) | Toggle voice recording (Option key) | Start and stop talking |
| **Right arrow** | Send (Enter key) | Submit what you said |
| **Left arrow** | Delete (Backspace key) | Remove what you just said if you misspoke |
| **Scroll up/down** (touchpad) | Scroll the screen | Read through output and code |
| **Bottom button** | Escape key | Interrupt the agent if it goes off track |

All of these mappings are customisable - see [Customising the controls](#customising-the-controls) below.

## How It Works

The JX-11 ring connects to your Mac over Bluetooth and presents itself as a media controller (like headphone buttons). This daemon intercepts those signals before macOS turns them into volume/mute commands, and translates them into keyboard actions.

By default, the voice recording toggle holds down the Option key, which triggers push-to-talk in voice-to-text apps. This works with any voice-to-text app that supports keyboard shortcuts - for example [FluidVoice](https://fluidvoice.ai/), [Superwhisper](https://superwhisper.com/), [Whisper Flow](https://whisperflow.com/), [Handy](https://handyai.app/), and [Every's Monologue](https://every.to/monologue). Just set your app's push-to-talk shortcut to match the key the bridge sends (Option by default), and you're good to go.

When you tap the ring, it starts recording. Tap again, it stops. Then press the right arrow to send your message.

## Hardware

- **Smart ring**: JX-11 Bluetooth ring (available on AliExpress/Amazon for ~$15)
- **Voice-to-text app**: Any app with a keyboard shortcut trigger ([FluidVoice](https://fluidvoice.ai/), [Superwhisper](https://superwhisper.com/), etc.)
- **Computer**: Mac running macOS (tested on macOS 15 Sequoia)
- **Wireless mic** (optional): DJI Mic, Rode Wireless Go, or any wireless microphone

You don't need a wireless mic. Your Mac's built-in microphone works fine when you're in the same room - the ring just lets you step back from your desk and not be tied to your keyboard. A wireless mic extends the range if you want to walk further away.

## Setup

### 1. Pair the ring

Put the JX-11 ring in pairing mode and connect it via Mac Bluetooth settings. It shows up as "JX-11".

### 2. Build the bridge

```bash
cd riff-bridge
make all
```

This compiles the Swift code and signs it with your Apple Developer certificate.

### 3. Grant permissions

The bridge needs two macOS permissions:

- **Input Monitoring** - to read the ring's button presses
- **Accessibility** - to send keyboard events to other apps

Go to System Settings > Privacy & Security and add the `riff-bridge` binary to both lists.

### 4. Install as a background service

```bash
make install
```

This sets up a LaunchAgent so the bridge starts automatically when you log in and restarts if it crashes.

### 5. Check it's running

```bash
tail -f /tmp/riff-bridge.log
```

You should see "Ring connected" and a list of available controls.

## Workflow

1. Put on the ring (and optionally clip on a wireless mic)
2. Open any app you want to talk to - a coding agent, chat interface, notes app, email, anything
3. Step back from your desk (or walk away if you have a wireless mic)
4. **Tap the ring** to start recording your voice
5. Speak naturally ("Create a new API endpoint for user profiles...")
6. **Tap again** to stop recording - your voice-to-text app transcribes it
7. **Press the right arrow** to send it
8. **Scroll the touchpad up/down** to read the response
9. **Press the bottom button** if you need to interrupt
10. **Press the left arrow** if you need to delete and start over

## Troubleshooting

**Ring not detected**: Make sure it's paired in Bluetooth settings and shows as "JX-11".

**Keys not working**: Check Input Monitoring and Accessibility permissions in System Settings > Privacy & Security.

**Bridge not starting**: Run `tail -f /tmp/riff-bridge.log` to see error messages.

**Scroll not working in terminal**: Make sure tmux has mouse mode enabled (`set -g mouse on` in your `.tmux.conf`).

## Files

| File | What it does |
|---|---|
| `riff_bridge.swift` | The main daemon code |
| `Makefile` | Build, sign, and install commands |
| `co.remotehumans.riff-bridge.plist` | LaunchAgent config (auto-start on login) |

## Customising the Controls

Every gesture mapping in this bridge is customisable. The defaults (Option key for voice toggle, Enter to send, etc.) are just what worked for one particular setup - you can change any of them to match your workflow.

The mappings live in `riff_bridge.swift` and are straightforward to modify. If you use an AI coding agent like [Claude Code](https://claude.com/claude-code), you can point it at this repo and ask it to change the mappings for you - for example, "change the tap gesture to trigger Cmd+Shift+A instead of Option" or "make the right swipe send Cmd+Enter instead of Enter". The code is intentionally simple so that AI agents (or you) can modify it easily.

**Common customisations:**
- Change the push-to-talk key to match your voice-to-text app's shortcut
- Map swipe gestures to different keyboard shortcuts
- Add new gesture combinations for app-specific actions
- Adjust scroll speed and sensitivity

## How This Was Built

If you want to adapt this for a different smart ring or Bluetooth device, here's the process we followed:

1. **Intercept the raw signals** - The JX-11 ring shows up as a HID (Human Interface Device) over Bluetooth. We used macOS IOKit HID Manager to listen for any input from the ring and log every signal it sent - button presses, touch events, swipe directions, everything.

2. **Map the signals** - By pressing each button and gesture on the ring while logging, we built a map of which HID usage codes correspond to which physical actions (tap, swipe left, swipe right, scroll, bottom button).

3. **Block the defaults** - The ring's signals arrive as media keys (volume up, volume down, mute), so macOS tries to handle them. We set up a CGEvent tap to intercept these events and block the default behaviour before they reach the system.

4. **Translate to useful keys** - With the raw signals identified and defaults blocked, we mapped each ring gesture to the keyboard events we actually wanted (Option key hold, Enter, Backspace, scroll events, Escape).

5. **Make it reliable** - Code-signed the binary for stable Accessibility permissions, set up a LaunchAgent so it auto-starts and restarts on crash.

This whole process was done with the help of an AI coding agent (Claude Code), which is a good example of the kind of thing you can build when you pair one with this ring.

## Tech Details

- Written in Swift, no external dependencies
- Uses IOKit HID Manager to read ring input (matched by VendorID/ProductID)
- Uses CGEvent tap to block default media key behaviour
- Timing correlation between IOKit and CGEvent callbacks prevents the ring's default volume/mute actions
- Continuous scroll events during Y-axis swipes for smooth scrolling
- Runs as a macOS LaunchAgent with KeepAlive for automatic restart
