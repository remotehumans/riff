# Riff Bridge - Smart Ring Controller

![Voice AI Workflow - Walk around, think out loud, build with AI](voice-ai-workflow-nb.jpg)

A macOS daemon that turns a cheap Bluetooth smart ring into a wireless controller for AI agents and any app that accepts text input.

## Supported Rings

| Ring | VendorID | ProductID | Price | Where to buy |
|---|---|---|---|---|
| **JX-11** | `0x05AC` | `0x0220` | ~$15 | AliExpress, Amazon |
| **JX-13** | `0x248A` | `0x8251` | ~$15 | AliExpress, Amazon |

The bridge auto-detects which ring is connected. Adding a new ring is a single line in the code — see [Adding a new ring](#adding-a-new-ring) below.

## What This Does

This lets you walk around your house, co-working space, or anywhere within Bluetooth range of your Mac and speak to your computer using just your voice and a smart ring on your finger.

Pair the ring with a wireless microphone (like a DJI wireless mic) and you can talk to AI agents like [Claude Code](https://claude.com/claude-code) and [Codex](https://openai.com/codex), dictate notes, write emails, or put text into any application - all without being at your desk or keyboard.

**The default ring controls:**

| Ring action | Default mapping | Why you need it |
|---|---|---|
| **Tap** (press button) | Toggle voice recording (Right Option key) | Start and stop talking |
| **Right arrow** | Send (Enter key) | Submit what you said |
| **Left arrow** | Delete (Backspace key) | Remove what you just said if you misspoke |
| **Scroll up/down** (touchpad) | Scroll the screen | Read through output and code |
| **Bottom button** | Escape key | Interrupt the agent if it goes off track |

> **Note:** The JX-13 only has a single button (no touchpad/swipe). It works perfectly for the core voice toggle workflow — tap to start, tap to stop.

All of these mappings are customisable - see [Customising the controls](#customising-the-controls) below.

## How It Works

The ring connects to your Mac over Bluetooth and presents itself as a media controller (like headphone buttons). This daemon intercepts those signals before macOS turns them into volume/mute commands, and translates them into keyboard actions.

The voice recording toggle sends a quick tap of the Right Option key, which triggers toggle-mode voice recording in voice-to-text apps. This works with any voice-to-text app that supports keyboard shortcuts - for example [FluidVoice](https://fluidvoice.ai/), [Superwhisper](https://superwhisper.com/), [Whisper Flow](https://whisperflow.com/), [Handy](https://handyai.app/), and [Every's Monologue](https://every.to/monologue). Just set your app's toggle shortcut to match the key the bridge sends (Right Option by default).

When you tap the ring, it starts recording. Tap again, it stops and your voice-to-text app transcribes and pastes the text.

## Hardware

- **Smart ring**: JX-11 or JX-13 Bluetooth ring (~$15 on AliExpress/Amazon)
- **Voice-to-text app**: Any app with a keyboard shortcut trigger ([FluidVoice](https://fluidvoice.ai/), [Superwhisper](https://superwhisper.com/), etc.)
- **Computer**: Mac running macOS (tested on macOS 15 Sequoia)
- **Wireless mic** (optional): DJI Mic, Rode Wireless Go, or any wireless microphone

You don't need a wireless mic. Your Mac's built-in microphone works fine when you're in the same room - the ring just lets you step back from your desk and not be tied to your keyboard. A wireless mic extends the range if you want to walk further away.

## Setup

### 1. Pair the ring

Put the ring in pairing mode (hold button until LED blinks rapidly) and connect it via Mac Bluetooth settings. It shows up as "JX-11" or "JX-13".

### 2. Build the bridge

```bash
cd riff-bridge
make all
```

This compiles the Swift code and signs it with your Apple Developer certificate.

> **No Apple Developer certificate?** That's fine — the binary still works unsigned for local use. You'll see a signing warning but it won't affect functionality.

### 3. Grant permissions

The bridge needs two macOS permissions:

- **Input Monitoring** - to read the ring's button presses
- **Accessibility** - to send keyboard events to other apps

Go to System Settings > Privacy & Security and add the `riff-bridge` binary to both lists.

### 4. Configure your voice-to-text app

Set your voice app's toggle/push-to-talk shortcut to **Right Option** key:
- **FluidVoice**: Settings → Shortcut → press Right Option
- **Superwhisper**: Preferences → Keyboard Shortcut → Right Option
- Other apps: find the keyboard shortcut setting and assign Right Option

### 5. Test it

```bash
./riff-bridge
```

You should see your ring detected and "Ring connected". Tap the ring — your voice app should start recording.

### 6. Install as a background service (optional)

```bash
make install
```

This sets up a LaunchAgent so the bridge starts automatically when you log in and restarts if it crashes. No terminal window needed.

```bash
tail -f /tmp/riff-bridge.log
```

To stop: `make uninstall`

## Usage

```bash
./riff-bridge              # auto-detect connected ring
./riff-bridge --ring JX-13 # force a specific ring
./riff-bridge --list       # show all supported rings
```

## Workflow

1. Put on the ring (and optionally clip on a wireless mic)
2. Open any app you want to talk to - a coding agent, chat interface, notes app, email, anything
3. Step back from your desk (or walk away if you have a wireless mic)
4. **Tap the ring** to start recording your voice
5. Speak naturally ("Create a new API endpoint for user profiles...")
6. **Tap again** to stop recording - your voice-to-text app transcribes it
7. (JX-11 only) **Swipe right** to send, **swipe left** to delete, **scroll** to read

## Ring-Specific Notes

### JX-13

- **Single button only** — no touchpad or swipe gestures
- Sends `volume_decrement` as HID event (consumer key, usage `0x00EA`)
- Sends duplicate events per tap — the bridge uses a 0.6s debounce to filter these
- Uses quick 50ms key tap (not hold) — works with toggle-mode voice apps like FluidVoice
- The ring may go to sleep after inactivity; press the button once to wake it before use
- If auto-detect fails after sleep, use `--ring JX-13` to force selection

### JX-11

- Full touchpad with swipe gestures (left, right, scroll)
- Bottom button for Escape/interrupt
- See the [original Riff repository](https://github.com/remotehumans/riff) for full JX-11 documentation

## Troubleshooting

**Ring not detected**: Make sure it's paired in Bluetooth settings. Try `--ring JX-13` (or `JX-11`) to force selection. Press the ring button to wake it from sleep.

**FluidVoice not responding to ring**: Check that FluidVoice's shortcut is set to Right Option. Test by physically pressing Right Option on your keyboard first — if that works but the ring doesn't, check Accessibility permissions.

**Double-tap required**: If you need to tap twice, the debounce may be too low for your ring. Edit `kTapDebounce` in `riff_bridge.swift` (default: 0.6s for JX-13).

**Keys not working**: Check Input Monitoring and Accessibility permissions in System Settings > Privacy & Security.

**Bridge not starting**: Run `tail -f /tmp/riff-bridge.log` to see error messages.

**Scroll not working in terminal**: Make sure tmux has mouse mode enabled (`set -g mouse on` in your `.tmux.conf`).

## Adding a New Ring

1. Pair the ring via Bluetooth
2. Find its IDs:
   ```bash
   system_profiler SPBluetoothDataType | grep -A 5 "YourRing"
   ```
3. Add one line to the `supportedRings` array in `riff_bridge.swift`:
   ```swift
   RingDevice(name: "YourRing", vendorID: 0xXXXX, productID: 0xYYYY),
   ```
4. Rebuild: `make all`

If the ring sends duplicate events per tap (common with cheap BT rings), increase `kTapDebounce` (default: 0.6s).

## Files

| File | What it does |
|---|---|
| `riff_bridge.swift` | The main daemon code |
| `Makefile` | Build, sign, and install commands |
| `co.remotehumans.riff-bridge.plist` | LaunchAgent config (auto-start on login) |

## Customising the Controls

Every gesture mapping in this bridge is customisable. The defaults (Right Option key for voice toggle, Enter to send, etc.) are just what worked for one particular setup - you can change any of them to match your workflow.

The mappings live in `riff_bridge.swift` and are straightforward to modify. If you use an AI coding agent like [Claude Code](https://claude.com/claude-code), you can point it at this repo and ask it to change the mappings for you - for example, "change the tap gesture to trigger Cmd+Shift+A instead of Right Option" or "make the right swipe send Cmd+Enter instead of Enter". The code is intentionally simple so that AI agents (or you) can modify it easily.

**Common customisations:**
- Change the voice toggle key to match your voice-to-text app's shortcut
- Map swipe gestures to different keyboard shortcuts
- Add new gesture combinations for app-specific actions
- Adjust scroll speed and sensitivity
- Change `kTapDebounce` if your ring double-fires

## How This Was Built

If you want to adapt this for a different smart ring or Bluetooth device, here's the process:

1. **Intercept the raw signals** - The ring shows up as a HID (Human Interface Device) over Bluetooth. We used macOS IOKit HID Manager to listen for any input from the ring and log every signal it sent - button presses, touch events, swipe directions, everything.

2. **Map the signals** - By pressing each button and gesture on the ring while logging (Karabiner-EventViewer is great for this), we built a map of which HID usage codes correspond to which physical actions.

3. **Block the defaults** - The ring's signals arrive as media keys (volume up, volume down, mute), so macOS tries to handle them. We set up a CGEvent tap to intercept these events and block the default behaviour before they reach the system.

4. **Translate to useful keys** - With the raw signals identified and defaults blocked, we mapped each ring gesture to the keyboard events we actually wanted (Option key tap, Enter, Backspace, scroll events, Escape).

5. **Make it reliable** - Set up a LaunchAgent so it auto-starts and restarts on crash, with a health check timer that reinstalls the event tap if macOS disables it.

## Tech Details

- Written in Swift, no external dependencies
- Multi-device support via `RingDevice` registry (auto-detection + `--ring` flag)
- Uses IOKit HID Manager to read ring input (matched by VendorID/ProductID)
- Uses CGEvent tap to block default media key behaviour
- Timing correlation between IOKit and CGEvent callbacks prevents the ring's default volume/mute actions
- Quick key tap (50ms press+release) for toggle-mode voice apps
- 0.6s debounce for rings that send duplicate HID events
- Continuous scroll events during Y-axis swipes for smooth scrolling
- Runs as a macOS LaunchAgent with KeepAlive for automatic restart

## Credits

Originally built by [Remote Humans](https://www.remotehumans.ai/) for the JX-11 ring. JX-13 multi-device support contributed by [Morgan Schofield](https://github.com/MorganOnCode).
