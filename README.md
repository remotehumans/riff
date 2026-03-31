# Riff

![Riff Workflow - Walk around, think out loud, build with AI](riff-bridge/voice-ai-workflow-nb.jpg)

**Walk around. Think out loud. Talk to your computer.**

Riff is two independent tools for hands-free interaction with AI agents and any app that accepts text input. Use one or both - they work together but neither requires the other.

**Riff Bridge** lets you speak to your computer from across the room using a smart ring and your voice. The ring triggers your voice-to-text app, and you control everything with gestures - send, delete, scroll, interrupt. It works with AI coding agents like Claude Code and Codex, but also chat interfaces, note-taking apps, email - anything you can type into.

**Riff Voice** gives your AI agents a voice. It speaks summaries of what your agents are doing aloud through your speakers, so you can hear task completions, errors, and progress updates without looking at the screen.

## Components

### [Riff Bridge](riff-bridge/) - Smart Ring Controller

A macOS daemon that turns a ~$15 Bluetooth smart ring (JX-11) into a wireless controller. Pair it with any voice-to-text app and you can talk to your computer hands-free from anywhere in Bluetooth range.

**What you get**: Step back from your desk - or walk to another room with a wireless mic - and speak instructions to AI agents, dictate notes, write emails, or put text into any app. All controlled by ring gestures.

**You need**: A JX-11 ring, a voice-to-text app, and a Mac.

```bash
cd riff-bridge
make install
```

[Full setup guide &rarr;](riff-bridge/README.md)

### [Riff Voice](riff-voice/) - Voice Narrator for AI Agents

A macOS daemon that gives your AI agents a voice. It speaks summaries of agent activity aloud using on-device TTS (Kokoro via MLX on Apple Silicon) - so you hear when tasks start, finish, hit errors, or need attention. No API keys, no cloud, no latency.

**What you get**: Walk away from your desk and still know what your agents are doing. Riff Voice narrates session summaries, completions, and errors through your speakers or headphones.

**You need**: A Mac with Apple Silicon (M1+).

```bash
cd riff-voice
make install
```

[Full setup guide &rarr;](riff-voice/README.md)

## Use Them Together or Separately

| Setup | What you can do |
|---|---|
| **Riff Bridge only** | Speak to AI agents or any app via ring gestures. Read output on screen. |
| **Riff Voice only** | Type at your desk as normal. Hear agent output spoken aloud. |
| **Both** | Full hands-free loop: speak instructions via ring, hear responses via Riff Voice. Walk around and build. |

Most people start with **Riff Bridge** - it's the core "walk around and talk to your computer" experience. Add **Riff Voice** later if you want audio feedback without looking at the screen.

## Hardware

| Item | Cost | Required? | Where to get it |
|---|---|---|---|
| JX-11 Smart Ring | ~$15 | Yes | AliExpress, Amazon |
| Voice-to-text app | Free-$10 | Yes | [FluidVoice](https://fluidvoice.ai/), [Superwhisper](https://superwhisper.com/), [Whisper Flow](https://whisperflow.com/), [Handy](https://handyai.app/), or any app with a keyboard shortcut trigger |
| Wireless microphone | $30-300 | Optional | DJI Mic, Rode Wireless Go, or any BT/wireless mic |

**You don't need a wireless mic to get started.** The ring works with your Mac's built-in microphone - you just need to be in the same room. This alone lets you step back from your desk, stand up, and interact with your computer without being glued to your keyboard. A wireless mic extends the range so you can walk to another room, but it's not required.

## Requirements

- macOS (tested on macOS 15 Sequoia)
- Apple Silicon (M1+) required for Riff Voice (Riff Bridge works on Intel too)
- A voice-to-text app with a configurable keyboard shortcut (push-to-talk)

---

## Built by Remote Humans

Riff is built by [Remote Humans](https://www.remotehumans.ai/) - we help business owners and leaders actually use AI in their day-to-day work, not just talk about it.

- **[Leader Lab](https://www.remotehumans.ai/leader-lab)** - 1:1 AI coaching for business owners and leaders who want to work with AI the way we do
- **[Build & Embed](https://www.remotehumans.ai/build-embed)** - We build custom AI workflows and tools directly into your business

## Licence

MIT
