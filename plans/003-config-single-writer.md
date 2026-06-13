# Plan 003: Make the daemon the single writer of config.json (RiffBar stops editing the file directly)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 56bd58c..HEAD -- riff-voice/src/riff/ riff-voice/RiffBar/DaemonConnection.swift`
> Plan 002 intentionally touches these files first — its changes (async
> `list_devices`, added `config.save()` calls, reordered `popoverOpened`)
> are EXPECTED drift; reconcile excerpts against them. Any other mismatch
> is a STOP condition.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: LOW-MED (protocol additions; settings UI behaviour must be manually verified)
- **Depends on**: plans/002-daemon-event-loop-blocking.md (persistence calls + handler shape)
- **Category**: bug / tech-debt
- **Planned at**: commit `56bd58c`, 2026-06-12

## Why this matters

Two processes write `~/.config/riff/config.json` with no coordination, and the daemon never re-reads it. The daemon loads config **once at startup** into an in-memory dataclass and rewrites the **entire file** from memory whenever it saves (auto-naming a session, `set_name`, `set_output_device`). RiffBar meanwhile writes `default_voice`, `announcer_voice`, and session clears **directly into the file**. Concrete user-visible bug: change the Default Voice in RiffBar Settings → minutes later a new Claude Code session triggers the daemon's auto-name save → the daemon writes its stale in-memory `default_voice` back, silently reverting the user's choice. "Clear All Sessions" is similarly undone by the next daemon save. This explains "settings don't stick" weirdness and will corrupt any future config field the same way.

The fix is ownership: every config mutation goes through the daemon socket; RiffBar never writes the file. RiffBar's config *reads* (it currently re-parses the file on mod-time change to list sessions) are replaced by a `get_config` command, removing the file from the UI's hot path entirely.

## Current state

- `riff-voice/src/riff/config.py` — `RiffConfig` dataclass; `load()` (lines 43–69) reads the file once; `save()` (lines 71–76) writes `asdict(self)` wholesale. No reload mechanism exists.
- `riff-voice/src/riff/daemon.py` — handlers mutate `self.config` and (after plan 002) call `self.config.save()`. `_dispatch` (lines 353–382) routes commands; existing commands: `speak, interrupt, skip, status, read_full, set_voice, set_enabled, set_speed, set_name, list_voices, list_devices, set_output_device`. There is **no** `get_config`, `set_default_voice`, `set_announcer_voice`, or `clear_sessions`.
- `riff-voice/RiffBar/DaemonConnection.swift` — the offending direct file access:
  - `configPath` property (lines 26–27): `~/.config/riff/config.json`.
  - `loadConfigDict()` / `saveConfigDict()` (lines 299–310): raw JSONSerialization read/write of the file.
  - `setDefaultVoice(_:)` and `setAnnouncerVoice(_:)` (lines 197–211): mutate the dict and write the file.
  - `clearAllSessions()` (lines 183–191): empties `session_names`/`voice_map` in the file.
  - `fetchStatus()` (lines 76–108): on each poll, stats the file's mod time and re-parses it via `loadConfigDict()` to refresh `sessions`, `defaultVoice`, `announcerVoice` through `applyConfig(_:)` (lines 408–420).
- `riff-voice/RiffBar/SettingsView.swift` — Settings UI calling `daemon.setDefaultVoice/setAnnouncerVoice` (lines 61–98) and `daemon.clearAllSessions()` (line 188). No changes needed here if DaemonConnection keeps the same method names.
- Tests: `riff-voice/tests/test_daemon_handlers.py` exists after plan 002 — extend it, follow its monkeypatching pattern for `CONFIG_PATH`.

Conventions: handlers are small `_handle_*` methods returning dicts; errors are `{"error": "..."}`; success is `{"ok": True, ...}`. Match `_handle_set_name` (daemon.py:536–545) as the exemplar. Python files start with two `# ABOUTME:` lines.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Syntax check | `cd riff-voice && uv run python -m py_compile src/riff/daemon.py src/riff/config.py` | exit 0 |
| Tests | `cd riff-voice && uv run --group dev pytest -q` | all pass |
| Restart daemon | `launchctl bootout gui/$(id -u)/co.remotehumans.riff-voice 2>/dev/null; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/co.remotehumans.riff-voice.plist` | exit 0; wait for "Listening on" in `/tmp/riff.log` |
| Build RiffBar | `cd riff-voice/RiffBar && bash build.sh` | "RiffBar built successfully." |
| Restart RiffBar | `launchctl bootout gui/$(id -u)/co.remotehumans.riff-bar 2>/dev/null; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/co.remotehumans.riff-bar.plist` | menu bar icon appears |
| Raw socket probe | `printf '{"type":"get_config"}\n' \| nc -U /tmp/riff.sock` | JSON config |

## Scope

**In scope** (the only files you should modify):
- `riff-voice/src/riff/daemon.py` (new handlers)
- `riff-voice/RiffBar/DaemonConnection.swift` (replace file I/O with socket calls)
- `riff-voice/tests/test_daemon_handlers.py` (extend)

**Out of scope** (do NOT touch, even though they look related):
- `riff-voice/src/riff/config.py` — `load()`/`save()` stay as they are; single-writer makes them safe.
- `riff-voice/RiffBar/SettingsView.swift`, `PopoverView.swift` — the DaemonConnection method signatures are preserved so views don't change.
- `riff-voice/src/riff/cli.py` — no new CLI subcommands in this plan (deferred; note in README if wanted).
- `~/.config/riff/config.json` format/keys — no schema changes.

## Git workflow

- Branch: `advisor/003-config-single-writer`
- Conventional commits, e.g. `fix(riff-voice): route all config writes through the daemon`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Add `get_config`, `set_default_voice`, `set_announcer_voice`, `clear_sessions` to the daemon

In `daemon.py`, add four handlers and route them in `_dispatch`:

- `_handle_get_config()` → `{"ok": True, "config": {"default_voice": ..., "announcer_voice": ..., "session_names": {...}, "voice_map": {...}, "enabled": ..., "speed": ..., "output_device": ...}}` (build from `self.config`; do not dump `asdict` blindly — list the keys so accidental future secrets in config don't leak through the socket).
- `_handle_set_default_voice(msg)` / `_handle_set_announcer_voice(msg)` → validate against `KOKORO_VOICES` exactly like `_handle_set_voice` (daemon.py:497–507), assign `self.config.default_voice` / `announcer_voice`, `self.config.save()`, return `{"ok": True, ...}`.
- `_handle_clear_sessions()` → empty `self.config.session_names` and `self.config.voice_map`, `save()`, log, return `{"ok": True}`.

**Verify**: `uv run python -m py_compile src/riff/daemon.py` → exit 0. Restart daemon, then `printf '{"type":"set_default_voice","voice":"bm_george"}\n' | nc -U /tmp/riff.sock` → `{"ok": true, ...}` and `python3 -c "import json;print(json.load(open('$HOME/.config/riff/config.json'))['default_voice'])"` → `bm_george`. Restore your previous default voice afterwards via the same command.

### Step 2: RiffBar — replace file writes with socket commands

In `DaemonConnection.swift`, keeping method names and signatures identical so the views compile untouched:

- `setDefaultVoice(_:)` → set the published var optimistically, then `fire(["type": "set_default_voice", "voice": voice])`.
- `setAnnouncerVoice(_:)` → same with `set_announcer_voice`.
- `clearAllSessions()` → `fire(["type": "clear_sessions"])` then `fetchConfig()`.
- Delete `saveConfigDict(_:)` entirely.

**Verify**: `cd riff-voice/RiffBar && bash build.sh` → success, and `grep -n "saveConfigDict\|data.write(to: configPath)" DaemonConnection.swift` → no matches.

### Step 3: RiffBar — replace file reads with `get_config`

- Add `fetchConfig()`: sends `{"type": "get_config"}`, parses `response["config"]`, and feeds it through the existing `applyConfig(_:)` (lines 408–420) — `applyConfig` already takes a `[String: Any]`, so the daemon's JSON maps directly.
- In `fetchStatus()` (lines 76–108), remove the mod-time stat + `loadConfigDict()` block; instead call `fetchConfig()` from `popoverOpened()` and after any mutation (`setVoice`, `setName`, `clearAllSessions`). To keep sessions fresh while the popover is open, also call `fetchConfig()` on a slow cadence: piggyback on the existing poll by calling it every Nth `fetchStatus()` while `pollInterval == 2.0` (popover open) — a simple counter is fine.
- `loadConfig()`/`loadConfigDict()` may remain only as the **initial** state seed before the daemon connects (daemon may still be loading its model at login); mark them with a comment that they are read-only fallback.

**Verify**: build succeeds. Restart both daemon and RiffBar. In RiffBar Settings change Default Voice to `bf_emma`; then trigger a daemon save by `riff-ctl name testsession 'Test Session'`; then `python3 -c "import json;c=json.load(open('$HOME/.config/riff/config.json'));print(c['default_voice'])"` → **`bf_emma`** (before this plan, the daemon's save would have reverted it). Clean up: `riff-ctl` has no delete-name command — use RiffBar "Clear All Sessions", then confirm the file shows empty `session_names` and it STAYS empty after `riff-say "hello" --session sanity-check` adds only the new session.

## Test plan

Extend `riff-voice/tests/test_daemon_handlers.py` (pattern from plan 002 — `CONFIG_PATH` monkeypatched to tmp):

1. `set_default_voice` with valid voice → ok, file on disk updated.
2. `set_default_voice` with bogus voice → `{"error": ...}`, file untouched.
3. `set_announcer_voice` valid → persisted.
4. `clear_sessions` → in-memory and on-disk `session_names`/`voice_map` empty.
5. `get_config` → returns exactly the documented keys (assert key set equality, so future leaks are caught).
6. Regression for the clobber bug: simulate "external edit then daemon save" — after `set_default_voice`, call `_handle_set_name` and assert `default_voice` in the file is still the new value.

**Verification**: `cd riff-voice && uv run --group dev pytest -q` → all pass (≥11 total with plan 002's).

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `uv run python -m py_compile src/riff/daemon.py` exits 0
- [ ] `uv run --group dev pytest -q` exits 0, including the 6 new tests
- [ ] `grep -n "saveConfigDict" riff-voice/RiffBar/DaemonConnection.swift` → no matches
- [ ] `bash riff-voice/RiffBar/build.sh` exits 0
- [ ] Manual clobber repro (Step 3 verify) shows the default voice surviving a daemon-side save
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Plan 002 has not landed (no `tests/` directory, `_handle_set_voice` lacks `config.save()`) — execute 002 first or report.
- `applyConfig(_:)` in the live code no longer accepts a `[String: Any]` (plan 001's executor restructured DaemonConnection more than expected).
- The views fail to compile after Step 2 despite unchanged method signatures — report the compiler error rather than editing SettingsView/PopoverView beyond a call-site rename.
- You find additional RiffBar file-write paths not listed in "Current state" (search first: `grep -n "configPath" DaemonConnection.swift`) — list them in the report; widening scope silently is not allowed.

## Maintenance notes

- From now on the rule is: **config.json has one writer — the daemon.** Any new setting needs a socket command, not a file edit. Reviewers should reject PRs that reintroduce `saveConfigDict`.
- `get_config` whitelists keys; when adding a config field, add it there deliberately.
- Deferred (recorded in README): file-watch or push notifications from daemon to RiffBar instead of polling; `riff-ctl config` subcommand for shell access to `get_config`.
