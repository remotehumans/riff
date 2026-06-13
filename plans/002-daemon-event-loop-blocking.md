# Plan 002: Stop the daemon blocking its event loop on device rescans, and persist runtime settings

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 56bd58c..HEAD -- riff-voice/src/riff/ riff-voice/RiffBar/DaemonConnection.swift`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none (independent of plan 001; both attack the "slow toggle" symptom from different ends)
- **Category**: perf / bug
- **Planned at**: commit `56bd58c`, 2026-06-12

## Why this matters

Opening the RiffBar popover fires three requests at the daemon: `list_voices`, `list_devices`, `status`. The `list_devices` handler **tears down and reinitialises PortAudio synchronously inside the asyncio event loop** (`sd._terminate()` / `sd._initialize()`), which takes from hundreds of milliseconds to several seconds when Bluetooth audio devices are present. While that runs, the daemon cannot answer *any* other request — including the `set_enabled` toggle and the 2-second status polls. On the RiffBar side, all requests go through **one serial DispatchQueue** with a 2s receive timeout, so a slow `list_devices` makes everything behind it (the Enabled toggle, the speed slider) feel stuck. This is the second half of the user-reported "enable/disable is very slow" complaint (plan 001 is the first half).

Two adjacent correctness bugs live in the same handlers, fixed here because they're one-line each: (1) reinitialising PortAudio while the speech worker is playing audio through it can kill or corrupt active playback (`sd` module state is global and `_play_audio` runs concurrently in an executor thread); (2) `set_enabled`, `set_speed`, and `set_voice` mutate in-memory config but never call `config.save()`, so disabling Riff or changing speed silently reverts whenever the daemon restarts (`launchctl` KeepAlive restarts it on any crash).

## Current state

- `riff-voice/src/riff/daemon.py` — the asyncio daemon. Single event loop; one `speech_worker` task plays audio via `run_in_executor`; `handle_client` reads JSON lines and awaits `_dispatch` (lines 353–382), whose handlers are all **synchronous** methods called directly on the event loop.

The blocking rescan, `daemon.py:550-556`:

```python
    def _handle_list_devices(self) -> dict[str, Any]:
        # Re-scan audio devices so hot-plugged devices appear
        sd._terminate()
        sd._initialize()
        devices = sd.query_devices()
```

The non-persisting handlers, `daemon.py:497-534` (note: `_handle_set_name` at 536–545 *does* call `self.config.save()` — that is the pattern to match):

```python
    def _handle_set_voice(self, msg):
        ...
        self.config.voice_map[session] = voice          # no save()
    def _handle_set_enabled(self, msg):
        ...
        self.config.enabled = bool(enabled)             # no save()
    def _handle_set_speed(self, msg):
        ...
        self.config.speed = speed                       # no save()
```

Playback state flag: `self.speaking` is set/cleared in `speech_worker` (`daemon.py:283`, `320`). `_play_audio` (lines 234–270) runs in the default executor and already contains its own `sd._terminate()/_initialize()` retry on `PortAudioError` — that retry path is acceptable because it only runs when playback already failed.

- `riff-voice/RiffBar/DaemonConnection.swift` — menu bar app's socket client. One serial queue for ALL requests, `DaemonConnection.swift:29`:

```swift
    private let requestQueue = DispatchQueue(label: "com.riffbar.daemon-connection", qos: .utility)
```

`popoverOpened()` (lines 44–49) calls `fetchVoices()`, `fetchDevices()`, `fetchStatus()` in that order — so the status fetch and any user action queue behind the device rescan. `sendRequest` (lines 321–406) opens a fresh socket per request with a 2s `SO_RCVTIMEO`.

- `riff-voice/src/riff/config.py` — `RiffConfig` dataclass with `save()` writing `~/.config/riff/config.json`. (Who owns this file is plan 003's problem; here we only add the missing `save()` calls, matching `_handle_set_name`.)
- `riff-voice/src/riff/cli.py` — `riff-ctl` CLI; `riff-ctl status` round-trips the socket and is the easiest latency probe.

Repo conventions: Python files start with two `# ABOUTME:` lines; daemon logs via the module-level `log()` helper; handlers return dicts that are JSON-serialised by `handle_client`. Python ≥3.10, managed with uv (`uv sync`, `uv run`).

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Install deps | `cd riff-voice && uv sync` | exit 0 |
| Syntax check | `cd riff-voice && uv run python -m py_compile src/riff/daemon.py src/riff/config.py` | exit 0, no output |
| Restart daemon | `launchctl bootout gui/$(id -u)/co.remotehumans.riff-voice 2>/dev/null; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/co.remotehumans.riff-voice.plist` | exit 0 |
| Daemon log | `tail -20 /tmp/riff.log` | "Listening on /tmp/riff.sock" after model load |
| Status probe | `time riff-ctl status` | JSON response; see per-step latency targets |
| Speak test | `riff-say "testing"` | `{"ok": true, ...}` and audible speech |

The daemon takes ~10–30s after restart to load the Kokoro model before the socket exists — wait for "Listening on" in the log before probing.

## Scope

**In scope** (the only files you should modify):
- `riff-voice/src/riff/daemon.py`
- `riff-voice/RiffBar/DaemonConnection.swift` (one ordering change + request param only)
- `riff-voice/tests/test_daemon_handlers.py` (create — see Test plan)
- `riff-voice/pyproject.toml` (add pytest as a dev dependency only)

**Out of scope** (do NOT touch, even though they look related):
- The RiffBar popover view hierarchy / `MenuBarExtra` — that is plan 001.
- RiffBar's direct reads/writes of `config.json` (`loadConfigDict`/`saveConfigDict`) — that is plan 003. Do not "fix" config ownership here.
- `riff-bridge/` entirely.
- The socket protocol message names that already exist (`list_devices`, `set_enabled`, …) — additive params only, so older CLI clients keep working.

## Git workflow

- Branch: `advisor/002-daemon-event-loop`
- Conventional commits, e.g. `perf(riff-voice): move device rescan off the event loop`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Make `list_devices` non-blocking and rescan-optional

In `daemon.py`:

1. Split `_handle_list_devices` into a synchronous `_scan_devices(rescan: bool)` (the existing body, with `sd._terminate()/_initialize()` executed only when `rescan` is true **and** `self.speaking` is false) and an `async def _handle_list_devices(self, msg)` that runs `_scan_devices` via `await loop.run_in_executor(None, ...)`.
2. Read the flag from the message: `rescan = bool(msg.get("rescan", False))`. Default false — a plain `query_devices()` call is fast and safe.
3. In `_dispatch`, `list_devices` is currently called without the msg argument (`daemon.py:377-378`) — pass `msg` and `await` the new coroutine. `_dispatch` is already `async`, so only this branch changes shape.
4. When `rescan` is requested while `self.speaking` is true, skip the reinit and include `"rescan_skipped": true` in the response (log it with `log()`).

**Verify**: `cd riff-voice && uv run python -m py_compile src/riff/daemon.py` → exit 0. Then restart the daemon, wait for "Listening on", and run `printf '{"type":"list_devices"}\n' | nc -U /tmp/riff.sock | head -c 200` → JSON containing `"output_devices"`.

### Step 2: Prove the event loop stays responsive during a rescan

With the daemon running, fire a rescan and a status probe concurrently:

```bash
(printf '{"type":"list_devices","rescan":true}\n' | nc -U /tmp/riff.sock >/dev/null &) ; time riff-ctl status
```

**Verify**: `riff-ctl status` completes in < 0.3s real time (previously it would block for the duration of the PortAudio reinit).

### Step 3: Persist `set_enabled`, `set_speed`, `set_voice`

Add `self.config.save()` to `_handle_set_enabled`, `_handle_set_speed`, and `_handle_set_voice` in `daemon.py`, exactly matching the pattern in `_handle_set_name` (`daemon.py:536-545`).

**Verify**:
```bash
riff-ctl disable && riff-ctl speed 1.7 && python3 -c "import json;c=json.load(open('$HOME/.config/riff/config.json'));print(c['enabled'],c['speed'])"
```
→ prints `False 1.7`. Then `riff-ctl enable` and confirm the file shows `true` again.

### Step 4: RiffBar — fetch status first, rescan only on explicit refresh

In `DaemonConnection.swift`:

1. Reorder `popoverOpened()` (lines 44–49) to `fetchStatus()` → `fetchDevices()` → `fetchVoices()` so the UI's freshest-needed data wins the serial queue.
2. Change `fetchDevices()` to send `["type": "list_devices"]` (no rescan — now fast by default), and add a `fetchDevices(rescan: Bool)` variant that sends `"rescan": true`; wire the refresh button in `PopoverView.swift:204-215`'s action to `daemon.fetchDevices(rescan: true)`. (This is the one permitted touch outside DaemonConnection: the single call-site argument in `PopoverView.swift`. If plan 001 restructured that button, adapt the call site only.)

**Verify**: `cd riff-voice/RiffBar && bash build.sh` → "RiffBar built successfully." Restart RiffBar (`launchctl bootout gui/$(id -u)/co.remotehumans.riff-bar 2>/dev/null; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/co.remotehumans.riff-bar.plist`), open the popover, and toggle Enabled twice — each toggle must reflect in `riff-ctl status` within 1 second.

## Test plan

The repo currently has **zero tests**. Create the first ones for the pure handler logic (no audio I/O):

- File: `riff-voice/tests/test_daemon_handlers.py`. Add `pytest` to a `[dependency-groups] dev` group in `pyproject.toml`; run with `uv run --group dev pytest`.
- Construct `RiffDaemon(RiffConfig(...))` pointing `RiffConfig` saves at a `tmp_path` config file (pass `path` to `save` via monkeypatching `CONFIG_PATH` or by calling `config.save(tmp_path / "config.json")` — `RiffConfig.save()` already accepts a `path` argument; monkeypatch `riff.config.CONFIG_PATH` so handler-internal `save()` calls land in tmp).
- Cases:
  1. `_handle_set_speed({"speed": 1.7})` returns ok **and** the config file on disk contains `"speed": 1.7` (regression for the persistence bug).
  2. `_handle_set_enabled({"enabled": False})` persists `"enabled": false`.
  3. `_handle_set_voice` with a valid voice persists into `voice_map`; with an invalid voice returns the error dict and does not write.
  4. `_handle_set_speed({"speed": 9})` returns the range error.
  5. `asyncio.run(daemon._handle_list_devices({"rescan": True}))` with `daemon.speaking = True` returns `"rescan_skipped": true` and must not call `sd._terminate` (monkeypatch `sounddevice._terminate` to raise if called).
- Do NOT write tests that require a real audio device or the MLX model; `sounddevice.query_devices` may be monkeypatched to return a fixed list.

**Verification**: `cd riff-voice && uv run --group dev pytest -q` → all pass (≥5 tests).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `uv run python -m py_compile src/riff/daemon.py src/riff/config.py` exits 0
- [ ] `uv run --group dev pytest -q` exits 0 with ≥5 passing tests
- [ ] Step 2's concurrent probe: `riff-ctl status` < 0.3s during an active rescan
- [ ] `riff-ctl disable` survives a daemon restart (config file shows `"enabled": false` and `riff-ctl status` after restart reports `"enabled": false`) — then re-enable
- [ ] `bash riff-voice/RiffBar/build.sh` exits 0
- [ ] `grep -n "sd._terminate" riff-voice/src/riff/daemon.py` shows it only inside `_scan_devices` (guarded) and the existing `_play_audio` retry path
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- `_dispatch` or `handle_client` in the live code no longer matches the excerpts (drift — plan 003 may have landed first and restructured handlers).
- Making `_handle_list_devices` async breaks other `_dispatch` branches in a way that requires converting *all* handlers to async — report instead; that's a larger refactor than this plan intends.
- The Step 2 latency target is missed even after the executor change — that points at a different blocker (e.g. the synthesis executor saturating the default thread pool); report the `py-spy dump` or sample output.
- pytest cannot run because `uv sync` fails to resolve `mlx-audio` on this machine.

## Maintenance notes

- Any new daemon command handler that does disk, subprocess, or PortAudio work must run it via `run_in_executor` — the event loop is the daemon's single point of responsiveness. A reviewer should reject future synchronous handlers.
- The `rescan` skip while speaking trades freshness for safety; if hot-plug-while-speaking matters later, the right fix is a lock shared between `_play_audio` and `_scan_devices`, not removing the guard.
- Plan 003 will move RiffBar's direct config-file writes behind daemon commands; the `save()` calls added here are what make the daemon the trustworthy single writer.
