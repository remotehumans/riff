# Voice AI

![Voice AI Workflow - Walk around, think out loud, build with AI](ring-bridge/voice-ai-workflow-nb.jpg)

**Walk around. Think out loud. Talk to your computer.**

A monorepo with two independent tools for hands-free interaction with AI agents and any app that accepts text input. Use one or both - they work together but neither requires the other.

The **ring-bridge** lets you speak to your computer from across the room using a smart ring and wireless mic. The ring triggers your voice-to-text app, and you control everything with gestures - send, delete, scroll, interrupt. It works with AI coding agents like Claude Code and Codex, but also chat interfaces, note-taking apps, email - anything you can type into.

**Riff** gives your AI agents a voice. It speaks summaries of what your agents are doing aloud through your speakers, so you can hear task completions, errors, and progress updates without looking at the screen.

## Components

### [ring-bridge](ring-bridge/) - Smart Ring Controller

A macOS daemon that turns a ~$15 Bluetooth smart ring (JX-11) into a wireless controller. Pair it with a wireless microphone and any voice-to-text app, and you can talk to your computer hands-free from anywhere in Bluetooth range.

**What you get**: Walk around your house or co-working space and speak instructions to AI agents, dictate notes, write emails, or put text into any app - all controlled by ring gestures.

**You need**: A JX-11 ring, a wireless microphone, a voice-to-text app, and a Mac.

```bash
cd ring-bridge
make install
```

[Full setup guide &rarr;](ring-bridge/README.md)

### [riff](riff/) - Voice Narrator for AI Agents

A macOS daemon that gives your AI agents a voice. It speaks summaries of agent activity aloud using on-device TTS (Kokoro via MLX on Apple Silicon) - so you hear when tasks start, finish, hit errors, or need attention. No API keys, no cloud, no latency.

**What you get**: Walk away from your desk and still know what your agents are doing. Riff narrates session summaries, completions, and errors through your speakers or headphones.

**You need**: A Mac with Apple Silicon (M1+).

```bash
cd riff
make install
```

[Full setup guide &rarr;](riff/README.md)

## Use Them Together or Separately

| Setup | What you can do |
|---|---|
| **ring-bridge only** | Speak to AI agents or any app via ring + wireless mic. Read output on screen. |
| **riff only** | Type at your desk as normal. Hear agent output spoken aloud. |
| **Both** | Full hands-free loop: speak instructions via ring, hear responses via riff. Walk around and build. |

Most people start with **ring-bridge** - it's the core "walk around and talk to your computer" experience. Add **riff** later if you want audio feedback without looking at the screen.

## Hardware

| Item | Cost | Where to get it |
|---|---|---|
| JX-11 Smart Ring | ~$15 | AliExpress, Amazon |
| Wireless microphone | $30-300 | DJI Mic, Rode Wireless Go, or any BT/wireless mic |
| Voice-to-text app | Free-$10 | [FluidVoice](https://fluidvoice.ai/), [Superwhisper](https://superwhisper.com/), [Whisper Flow](https://whisperflow.com/), [Handy](https://handyai.app/), or any app with a keyboard shortcut trigger |

## Requirements

- macOS (tested on macOS 15 Sequoia)
- Apple Silicon (M1+) required for riff (ring-bridge works on Intel too)
- A voice-to-text app with a configurable keyboard shortcut (push-to-talk)

## Licence

MIT
