# Plan 005: Riff Ear — wake-word voice control of the Mac (design + spike)

> **Executor instructions**: This is a DESIGN + SPIKE plan, not a
> build-everything plan. The deliverables are (a) a working end-to-end
> prototype on the happy path and (b) a written design doc recording the
> decisions the spike settles. Follow the steps in order; each milestone
> gates the next. If anything in the "STOP conditions" section occurs, stop
> and report — do not improvise. When done, update the status row in
> `plans/README.md`.
>
> **Drift check (run first)**: `git diff --stat 56bd58c..HEAD -- riff-voice/src/riff/`
> Plans 002/003 are expected to have landed (new daemon commands, async
> list_devices). The spike only *talks to* the daemon socket, so drift there
> is acceptable; verify the socket protocol commands used below still exist
> by running `riff-ctl status`.

## Status

- **Priority**: P2 (highest-value new capability; do after P1 fixes so the foundation is stable)
- **Effort**: L (spike itself: ~2–4 focused sessions; full product: out of scope here)
- **Risk**: MED (model/library choices may not meet latency targets; that's what the spike is for)
- **Depends on**: plans/001 and 002 (a responsive daemon and a sane menu bar app), not 003/004
- **Category**: direction
- **Planned at**: commit `56bd58c`, 2026-06-12

## Why this matters

The product owner's stated goal, verbatim intent: *"I would like it to become usable across my Mac such that I can interact with it through my voice... there would be a trigger word... it can have full access to my desktop... can pull up any app, can interact in any app... I don't need to click a button or shortcut."*

Today Riff covers the two ends of that loop but not the middle: **Riff Bridge** gives push-to-talk input (but requires a ring tap — a physical trigger), and **Riff Voice** speaks agent output aloud. What's missing is the hands-free *inbound* path: an always-listening daemon that hears a wake word, captures the spoken command, transcribes it locally, hands it to an agent that can control the Mac, and speaks the result back through the existing Riff Voice daemon. Architecturally this is a third sibling daemon — **riff-ear** — completing the trilogy: ear (listen) → brain (act) → voice (speak).

The repo's existing positioning constraint (root `README.md`: "No API keys, no cloud, no latency"; on-device Kokoro TTS) applies: wake word and STT must run locally. Agent execution uses the operator's existing subscription CLIs (`claude -p`), never raw API keys.

## Current state

- `riff-voice/src/riff/daemon.py` — TTS daemon; Unix socket `/tmp/riff.sock`; JSON-lines protocol; `speak` command queues speech (`{"type":"speak","text":...,"session":...}`). The spike sends its replies here — do not build new TTS.
- `riff-voice/src/riff/cli.py` — `riff-say` / `riff-ctl` show the minimal socket client pattern (`send_to_daemon`, lines 10–19). Copy this pattern for riff-ear's control CLI.
- `riff-bridge/riff_bridge.swift` — ring push-to-talk. Untouched by this plan; the ring remains a manual fallback/interrupt path. Its short-touch gesture already sends `{"type":"interrupt"}` to the voice daemon — riff-ear's barge-in should reuse that command.
- `riff-voice/co.remotehumans.riff-voice.plist` + `Makefile` — the LaunchAgent + `__INSTALL_DIR__` sed-templating install pattern to copy for riff-ear.
- Python tooling: uv-managed (`pyproject.toml`, `uv sync`), Python ≥3.10, MLX already a dependency (Apple Silicon required).
- Host machine facts (verify, don't assume, on other machines): Apple Silicon Mac, `~/agent-tools/transcribe/` contains a Parakeet-based transcription pipeline (`transcribe-single.sh`, ~70x realtime via Apple Neural Engine) proving parakeet-mlx works locally; `claude` CLI is installed and authenticated via subscription.
- Repo conventions: ABOUTME header comments on every source file; daemons log timestamped lines; JSON-lines-over-Unix-socket protocol; one folder per component at repo root (`riff-voice/`, `riff-bridge/` → new `riff-ear/`).

## The decisions this spike must settle (write the answers in the design doc)

1. **Wake-word engine.** Candidates, in recommended trial order:
   - `openWakeWord` (Apache-2.0, ONNX, Python) — free, custom phrases need training; ships pretrained "hey jarvis"-style models usable for proving the pipeline.
   - Picovoice Porcupine (free tier, custom "Hey Riff" keyword built in their console) — best accuracy/CPU, but requires an access key (conflicts with the "no API keys" ethos; key is for licensing not cloud inference — judgement call, record it).
   - Apple `SFSpeechRecognizer` on-device continuous recognition with keyword matching — no extra deps but historically battery-hungry and throttles long sessions.
   Decision criteria: false-accept rate over a 2-hour idle session (< 2), detection latency (< 500ms), idle CPU (< 5% of one efficiency core).
2. **STT for the command utterance.** parakeet-mlx (proven on this machine, ~70x realtime) vs whisper.cpp streaming. Decision criteria: ≤ 1.5s from end-of-speech to final transcript for a 10-second utterance; runs resident without hogging RAM (< 2GB).
3. **End-of-utterance detection.** Silence-based VAD (webrtcvad or silero-vad) with a ~800ms trailing-silence cutoff, vs push-to-stop via wake word ("over"). Start with silero-vad.
4. **The brain.** `claude -p "<transcript>"` per command with a system prompt + permission profile that grants computer control (the operator's machine already runs a computer-use MCP; AppleScript/`open -a` cover "pull up any app" cheaply). Decision criteria: command-to-first-action < 5s; cost-per-command acceptable on subscription; sessions: stateless per command for the spike, persistent conversation later.
5. **Safety gates.** Spoken confirmation before destructive/outward actions (delete, send, purchase). The spike hardcodes a deny-list of verbs that trigger "say confirm to proceed". Full policy design is product work, not spike work — but the doc must name the approach.
6. **Echo/barge-in.** While Riff Voice speaks, the mic hears it. Spike approach: suppress wake-word detection while `riff-ctl status` reports `speaking: true` (poll or subscribe), and treat the wake word during speech as an interrupt command instead. Acoustic echo cancellation is explicitly out of scope.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| New component env | `cd riff-ear && uv sync` | exit 0 |
| Run spike loop | `cd riff-ear && uv run riff-ear` | logs "listening for wake word" |
| Voice reply path | `riff-say "ear test"` | audible speech (daemon up) |
| Agent path | `claude -p "Say the word pong and nothing else." --max-turns 1` | prints pong |
| Mic sanity | `cd riff-ear && uv run python -c "import sounddevice as sd; print(sd.query_devices(kind='input'))"` | shows an input device |

## Scope

**In scope**:
- New directory `riff-ear/` (pyproject, `src/riff_ear/`, README, design doc `riff-ear/DESIGN.md`)
- Read-only use of the existing daemon socket and `claude` CLI
- A LaunchAgent plist + Makefile for riff-ear **only if** the spike passes its gates

**Out of scope** (do NOT touch):
- `riff-voice/` and `riff-bridge/` source — no protocol changes; if the spike seems to need one, record it in DESIGN.md as a proposal instead.
- Building custom wake-word model training pipelines.
- Acoustic echo cancellation, speaker identification, multi-user support.
- Granting the agent unattended sudo / Full Disk Access — macOS permission requests stay interactive.
- The root README sales copy — update it only after the feature ships for real, not for a spike.

## Git workflow

- Branch: `advisor/005-riff-ear-spike`
- Conventional commits per milestone, e.g. `feat(riff-ear): wake word detection loop (M1)`
- Do NOT push or open a PR unless the operator instructed it.

## Steps (milestone-gated)

### M1: Wake word in isolation

Scaffold `riff-ear/` with uv (`uv init --package`), add the chosen engine (start with openWakeWord; fall back per the decision table), and write `src/riff_ear/wake.py`: open the default input device via `sounddevice`, run detection, print a timestamped line per detection. Run it, say the wake phrase 10 times at desk distance.

**Gate**: ≥ 8/10 detections; zero false accepts over 30 minutes of normal room noise/music; idle CPU of the process < 10% (`top -pid`). Record actuals in DESIGN.md. If no engine passes after trying two, STOP and report.

### M2: Utterance capture + local STT

Add `src/riff_ear/listen.py`: after wake-word fire, record until silero-vad reports ~800ms trailing silence (cap 30s), then transcribe with parakeet-mlx (`parakeet-mlx` package; the proven model reference is in `~/agent-tools/transcribe/` — read its script for the model name rather than guessing). Print the transcript.

**Gate**: speak "open Safari and go to the BBC homepage" → printed transcript has ≥ 90% word accuracy; end-of-speech → transcript < 1.5s. Record actuals.

### M3: Brain round-trip

Add `src/riff_ear/brain.py`: send the transcript to `claude -p` with a fixed system prompt ("You control this Mac for its owner. Execute the spoken command using the tools available. Reply with one short spoken-style sentence describing the outcome.") and whatever tool permissions the operator's environment already grants `claude` (do not add API keys; do not edit `~/.claude/settings.json` — if permissions block an action, the spike reports that as a finding). Speak the reply by sending `{"type":"speak","text":...,"session":"riff-ear"}` to `/tmp/riff.sock` (copy `send_to_daemon` from `riff-voice/src/riff/cli.py:10-19`).

**Gate**: say the wake word + "open Safari" → Safari opens, and Riff speaks a one-line confirmation, fully hands-free, within 10s end-to-end. Demo at least 3 distinct commands (open app, simple in-app action, a question answered aloud).

### M4: Loop hardening (spike level)

Wire the pieces into `src/riff_ear/daemon.py` (single process, asyncio, mirroring riff-voice's structure): continuous wake-word loop, suppression while `riff-ctl status` reports speaking (poll the socket directly), wake-word-during-speech sends `{"type":"interrupt"}` instead, deny-list verbs trigger a spoken "say confirm to proceed" round. Add `riff-ear/Makefile` + LaunchAgent plist using the `__INSTALL_DIR__` sed pattern from `riff-voice/Makefile`.

**Gate**: a 1-hour session with the daemon installed: no crash (`launchctl print` shows running), no false-positive agent invocations, interrupt-by-voice works while Riff is mid-sentence.

### M5: Write DESIGN.md and the verdict

`riff-ear/DESIGN.md` (with ABOUTME lines): the six decisions with measured numbers, the architecture diagram (ear→brain→voice over the existing socket), the spike's known gaps (echo cancellation, persistent conversations, safety policy), and a recommended next-plan list. Honest verdicts are valuable: if latency or false-accept rates make this not-yet-viable, say so with numbers.

**Verify**: `test -f riff-ear/DESIGN.md` and it answers all six numbered decisions.

## Test plan

Spike-level: the milestone gates above are the tests, with measured numbers recorded in DESIGN.md. Unit tests are required only for pure logic introduced in M4 (deny-list matching, suppression-window logic) in `riff-ear/tests/` — model after `riff-voice/tests/test_daemon_handlers.py` if plan 002 has landed. Audio-path code is exempt from unit testing at spike stage.

## Done criteria

- [ ] `riff-ear/` exists with uv project, M1–M4 code, Makefile + plist
- [ ] All four milestone gates recorded as PASS/FAIL with measured numbers in `riff-ear/DESIGN.md`
- [ ] M3 demo: three hands-free commands executed and confirmed aloud (operator-witnessed or screen-recorded)
- [ ] Deny-list + suppression unit tests pass (`uv run --group dev pytest -q` in riff-ear)
- [ ] No modifications to `riff-voice/` or `riff-bridge/` source (`git status`)
- [ ] `plans/README.md` status row updated with the spike verdict (VIABLE / NOT-YET with reason)

## STOP conditions

Stop and report back (do not improvise) if:

- macOS microphone permission cannot be granted to the daemon context (LaunchAgent mic access is finicky — if `sounddevice` returns silence under launchctl but works in a terminal, report; the fix may need an app bundle wrapper, which is its own plan).
- No wake-word engine passes the M1 gate after two candidates.
- `claude -p` in this environment cannot perform any computer-control action due to permission profiles — report which permission was the blocker rather than weakening security settings yourself.
- Spike runtime exceeds 4 working sessions — write up what's done and the verdict so far.

## Maintenance notes

- riff-ear is deliberately a *third sibling*, not a feature of riff-voice — keeps the "use one or both" composability the README promises.
- The suppression-while-speaking design couples riff-ear to riff-voice's `status` shape (`speaking` bool); if plan 003+ adds push notifications over the socket, switch from polling to that.
- Future plans this spike should spawn (record in DESIGN.md): persistent conversation sessions, confirmation policy as config, app-bundle packaging for mic permissions, and replacing the polling suppression with an event stream.
