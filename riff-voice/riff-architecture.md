# Riff Architecture

```mermaid
graph TB
    subgraph You["🎧 You (Walking Around)"]
        Listen["Hear updates via headphones"]
        Ring["JX-11 Smart Ring"]
        Voice["Voice via FluidVoice"]
    end

    subgraph Apps["Your AI Agents & Apps"]
        CC1["Claude Code<br/>Session 1"]
        CC2["Claude Code<br/>Session 2"]
        Codex["Codex CLI"]
        Other["Other Apps"]
    end

    subgraph Riff["Riff Voice Narrator"]
        Hook["Stop Hook<br/><i>Extracts summary from<br/>agent responses</i>"]
        Socket["Unix Socket<br/>/tmp/riff.sock"]
        Queue["FIFO Queue<br/><i>One voice at a time</i>"]
        Namer["Session Namer<br/><i>Auto-generates friendly<br/>names from first message</i>"]
        Voices["Voice Registry<br/><i>54 Kokoro presets<br/>mapped per session</i>"]
        TTS["MLX Kokoro TTS<br/><i>82M params · Apple Silicon<br/>Local · No cloud</i>"]
    end

    subgraph Controls["Controls"]
        CLI["riff-say · riff-ctl"]
        MenuBar["Menu Bar App<br/><i>Phase 2</i>"]
    end

    CC1 -->|"on finish"| Hook
    CC2 -->|"on finish"| Hook
    Codex -.->|"Phase 2"| Socket
    Other -.->|"riff-say"| Socket

    Hook -->|"summary + session ID"| Socket
    Socket --> Namer
    Namer --> Queue
    Queue --> Voices
    Voices --> TTS
    TTS -->|"🔊 Speech"| Listen

    Ring -->|"Tap: dictate<br/>Swipe: send/delete<br/>Press: interrupt"| Voice
    Ring -->|"Escape button"| CLI
    CLI --> Socket
    MenuBar -.-> Socket

    Voice -.->|"Phase 3"| Socket

    style Riff fill:#1a1a2e,stroke:#e94560,color:#fff
    style You fill:#0f3460,stroke:#e94560,color:#fff
    style Apps fill:#16213e,stroke:#0f3460,color:#fff
    style Controls fill:#1a1a2e,stroke:#533483,color:#fff
    style TTS fill:#e94560,stroke:#fff,color:#fff
    style Queue fill:#533483,stroke:#fff,color:#fff
    style Namer fill:#533483,stroke:#fff,color:#fff
```

## The Flow

1. **Your AI agents work** - Claude Code, Codex, or any app finishes a task
2. **Hook captures the output** - extracts a spoken summary from the response
3. **Riff receives it** - via Unix socket, queues it (one voice at a time)
4. **Session is identified** - auto-named from content or labelled by the agent
5. **Voice is selected** - each session gets its own Kokoro voice preset
6. **You hear it** - MLX Kokoro speaks through your headphones, locally on Apple Silicon
7. **You interact** - ring to interrupt, voice to respond (Phase 3)
