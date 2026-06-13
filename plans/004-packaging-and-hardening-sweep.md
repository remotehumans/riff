# Plan 004: Fix fresh-install breakage (RiffBar plist), harden the Stop hook, and finish the ring device validation

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 56bd58c..HEAD -- riff-voice/RiffBar/co.remotehumans.riff-bar.plist riff-voice/Makefile riff-voice/riff-hook.sh riff-voice/riff-hook-processor.py riff-bridge/riff_bridge.swift`
> NOTE: at planning time the working tree already had an UNCOMMITTED change
> to `riff-voice/riff-hook-processor.py` (stdin fallback + a debug log line)
> — Step 3 absorbs it. Any other mismatch with the excerpts below is a STOP
> condition.

## Status

- **Priority**: P2
- **Effort**: S
- **Risk**: LOW
- **Depends on**: none
- **Category**: bug / security / dx
- **Planned at**: commit `56bd58c`, 2026-06-12

## Why this matters

Three small, unrelated-looking defects share one theme: the repo doesn't survive contact with a machine that isn't this exact Mac in this exact folder layout.

1. **Fresh installs of RiffBar are broken.** The repo's `co.remotehumans.riff-bar.plist` hardcodes an absolute path from an *old* folder layout (`voice-ai/riff/RiffBar/RiffBar` — the `riff/` directory no longer exists; the app lives at `riff-voice/RiffBar/`). The Makefile's `bar-install` target copies the plist verbatim, unlike the daemon's `install` target which correctly `sed`s an `__INSTALL_DIR__` token. Anyone running `make bar-install` (including the README's advertised flow) gets a LaunchAgent pointing at nothing. The currently working installed plist was evidently fixed by hand.
2. **The Claude Code Stop hook passes the entire hook JSON as a shell argv argument.** Large assistant messages risk `ARG_MAX`, and the JSON transits a process listing (`ps`) visible to other local processes. An uncommitted half-fix (stdin fallback) exists in the working tree; this plan lands it properly — stdin only, no argv. The hook's debug log also grows without bound in `/tmp` and records message content.
3. **The ring bridge's device-spoofing mitigation was never finished.** `riff-bridge/AUDIT.md` (2026-03-23) flagged HIGH: any BLE device advertising VendorID `0x05AC`/ProductID `0x0220` gets treated as the ring and can inject keystrokes. The fix constant `kJX11ExpectedName = "JX-11"` was added (riff_bridge.swift:24) but is referenced **nowhere** — validation was never implemented.

## Current state

- `riff-voice/RiffBar/co.remotehumans.riff-bar.plist` — stale hardcoded path:

```xml
<key>ProgramArguments</key>
<array>
    <string>/Users/elliott/Documents/AI Projects_local/voice-ai/riff/RiffBar/RiffBar</string>
</array>
```

- `riff-voice/Makefile` — `install` templates the daemon plist correctly (the pattern to copy):

```make
sed 's|__INSTALL_DIR__|$(CURDIR)|g' $(PLIST) > $(AGENT_DIR)/$(PLIST)
```

  but `bar-install` does `cp RiffBar/$(BAR_PLIST) $(AGENT_DIR)/$(BAR_PLIST)`.

- `riff-voice/riff-hook.sh` (17 lines) — reads stdin into `INPUT` and passes it as **argv**: `python3 "$PROCESSOR" "$INPUT" 2>/dev/null || true`.
- `riff-voice/riff-hook-processor.py` — `main()` at lines 72–96: committed version reads `sys.argv[1]`; the uncommitted working-tree version adds `else sys.stdin.read()` plus a `log(f"raw keys: ...")` line. `log()` (lines 15–17) appends unbounded to `/tmp/riff-hook-debug.log` and later lines log message content: `log(f"label={label}, speak_text={speak_text[:100]}")` (line ~104).
- The installed hook lives at `~/.claude/hooks/riff-hook.sh` (copied by `make install`) and is registered in `~/.claude/settings.json` under the Stop hook — after changing the repo copy you must re-copy it (`cp riff-voice/riff-hook.sh ~/.claude/hooks/riff-hook.sh`).
- `riff-bridge/riff_bridge.swift` — relevant excerpts:

```swift
// riff_bridge.swift:23-24
// Known serial number for the ring — reject unknown devices matching the same VID/PID
let kJX11ExpectedName: String = "JX-11"
```

```swift
// riff_bridge.swift:383-393 — match callback: logs but accepts ANY device
let hidMatchCallback: IOHIDDeviceCallback = { context, result, sender, device in
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
    ...
```

```swift
// riff_bridge.swift:335-345 — input callback: processes values with no device check
let ringInputCallback: IOHIDValueCallback = { ctx, result, sender, value in
    let element = IOHIDValueGetElement(value)
    ...
```

  The input callback is registered at **manager** level (line 380) deliberately — the ring exposes multiple HID interfaces and per-device registration misses some (see comment at lines 377–379). So validation must happen inside the callbacks, not by narrowing the match dictionary.

Conventions: ABOUTME header comments; constants grouped at the top of `riff_bridge.swift`; logging via `print("[\(ts())] ...")`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build bridge | `cd riff-bridge && make build` | `swiftc` exits 0 |
| Sign bridge | `cd riff-bridge && make sign` | signed (or documented warning) |
| Install bar plist | `cd riff-voice && make bar-install` | exit 0; plist in `~/Library/LaunchAgents` has real path |
| Hook syntax | `bash -n riff-voice/riff-hook.sh` | exit 0 |
| Hook dry-run | `echo '{"last_assistant_message":"SUMMARY [Test]: Hook dry run works.","session_id":"abcdef12","cwd":"/tmp"}' \| bash riff-voice/riff-hook.sh` | exit 0; spoken if daemon up |
| Python syntax | `cd riff-voice && uv run python -m py_compile riff-hook-processor.py` | exit 0 |

## Scope

**In scope** (the only files you should modify):
- `riff-voice/RiffBar/co.remotehumans.riff-bar.plist`
- `riff-voice/Makefile` (bar-install target only)
- `riff-voice/riff-hook.sh`
- `riff-voice/riff-hook-processor.py`
- `riff-bridge/riff_bridge.swift`
- `~/.claude/hooks/riff-hook.sh` (re-copy of the repo file — deployment, not a source edit)

**Out of scope** (do NOT touch, even though they look related):
- `riff-voice/src/riff/` — daemon internals (plans 002/003).
- `riff-voice/RiffBar/*.swift` — plan 001 owns those.
- `~/.claude/settings.json` — hook registration is already correct.
- The AUDIT.md thread-safety finding (#2) — single-thread contract is documented in the file header; leave it.

## Git workflow

- Branch: `advisor/004-packaging-hardening`
- One commit per step (4 commits), conventional style, e.g. `fix(riff-bar): template install path in LaunchAgent plist`
- The uncommitted working-tree change to `riff-hook-processor.py` gets absorbed into Step 3's commit — do not discard it without reading it first.
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Template the RiffBar plist path

Replace the hardcoded path in `riff-voice/RiffBar/co.remotehumans.riff-bar.plist` with `__INSTALL_DIR__/RiffBar/RiffBar` (where `__INSTALL_DIR__` is the riff-voice dir, matching the daemon plist's convention), and change the Makefile `bar-install` to template it exactly like `install` does:

```make
bar-install: bar
	mkdir -p $(AGENT_DIR)
	sed 's|__INSTALL_DIR__|$(CURDIR)|g' RiffBar/$(BAR_PLIST) > $(AGENT_DIR)/$(BAR_PLIST)
	-launchctl bootout gui/$$(id -u) $(AGENT_DIR)/$(BAR_PLIST) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENT_DIR)/$(BAR_PLIST)
```

**Verify**: `cd riff-voice && make bar-install && grep -A2 ProgramArguments ~/Library/LaunchAgents/co.remotehumans.riff-bar.plist` → shows the real absolute path ending in `riff-voice/RiffBar/RiffBar`; `pgrep -x RiffBar` → a PID (app relaunched).

### Step 2: Hook transport — stdin only

Change `riff-voice/riff-hook.sh` to stream stdin straight through instead of capturing into a variable and argv:

```bash
python3 "$PROCESSOR" 2>/dev/null || true
```

(keep the existing socket/processor existence guards; drop the `INPUT=$(cat ...)` line). In `riff-hook-processor.py` `main()`, read **only** stdin: `raw = sys.stdin.read()` — delete the `sys.argv[1]` branch so there's exactly one input path.

**Verify**: the hook dry-run command from the table → exit 0, and `tail -3 /tmp/riff-hook-debug.log` shows the entry; if the daemon is running you hear "Test says: Hook dry run works." Then deploy: `cp riff-voice/riff-hook.sh ~/.claude/hooks/riff-hook.sh && chmod +x ~/.claude/hooks/riff-hook.sh`.

### Step 3: Hook log hygiene

In `riff-hook-processor.py`:
1. Remove the `log(f"raw keys: ...")` debug line (uncommitted leftover) if present.
2. Stop logging message content: change `log(f"label={label}, speak_text={speak_text[:100]}")` to log lengths only, e.g. `log(f"label={label}, speak_len={len(speak_text)}")`.
3. Cap the log: at the top of `log()`, if the file exists and exceeds 1MB (`os.path.getsize`), truncate it (open with `"w"` once) before appending. Keep it dependency-free.

**Verify**: `uv run python -m py_compile riff-hook-processor.py` → exit 0; run the dry-run again; `grep -c "speak_text=" /tmp/riff-hook-debug.log` gains no new matches.

### Step 4: Ring bridge — enforce the device-name check

In `riff_bridge.swift`:

1. In `hidMatchCallback` (lines 383–393): after reading `name`, if `name != kJX11ExpectedName`, print a loud warning (`[!] Rejected HID device matching VID/PID but named '\(name)' — not \(kJX11ExpectedName)`) and **do not** re-enable the event tap for it; track legitimacy in a global `var ringDeviceValidated: Bool` style flag — but the load-bearing check is the next item.
2. In `ringInputCallback` (lines 335–345): derive the source device via `IOHIDElementGetDevice(IOHIDValueGetElement(value))`, read its `kIOHIDProductKey`, and `guard` it equals `kJX11ExpectedName` else return. Reading a string property per HID event is measurable overhead on swipe streams — cache validation: keep a small global set of validated device registry IDs (`IOHIDDeviceGetProperty(device, kIOHIDLocationIDKey)` or the device pointer itself via `ObjectIdentifier`/`Unmanaged` opaque value in a `Set<UInt>`), populated in `hidMatchCallback` and pruned in `hidRemoveCallback`; the input callback then does a set lookup only. All access happens on the main CFRunLoop (documented single-thread contract at lines 15–17), so no locking is needed — say so in a comment.
3. Build and re-deploy: `cd riff-bridge && make install` (templates plist + restarts the LaunchAgent).

**Verify**: `make build` exits 0. Functional check (requires the physical ring): tap the ring once — `/tmp` log or stdout shows "START recording"; tap again — "STOP recording". If the ring is not reachable, verify instead that the daemon starts cleanly (`launchctl print gui/$(id -u)/co.remotehumans.riff-bridge | grep state` → `state = running`) and note in the report that the physical-ring check is pending.

## Test plan

No test infrastructure exists for shell/Swift in this repo; verification is the per-step gates. The hook processor is plain Python — if plan 002's `tests/` directory exists, add `riff-voice/tests/test_hook_processor.py` with 3 tests for `extract_spoken_text` (imports via `importlib` from the repo root file): SUMMARY-with-label parsing, SUMMARY-without-label, and markdown-stripping fallback ≤ 400 chars. Skip this file (and say so in the report) if plan 002 hasn't landed.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `grep -c "__INSTALL_DIR__" riff-voice/RiffBar/co.remotehumans.riff-bar.plist` → 1, and `grep -rn "voice-ai/riff/RiffBar" riff-voice/` → no matches
- [ ] Installed plist (`~/Library/LaunchAgents/co.remotehumans.riff-bar.plist`) points at an existing binary (`test -x` the extracted path)
- [ ] `grep -n 'sys.argv' riff-voice/riff-hook-processor.py` → no matches; `grep -n 'INPUT=' riff-voice/riff-hook.sh` → no matches
- [ ] Hook dry-run exits 0 and produces a log entry without message content
- [ ] `grep -n "kJX11ExpectedName" riff-bridge/riff_bridge.swift` → ≥3 matches (declaration + match callback + input-callback validation)
- [ ] `cd riff-bridge && make build` exits 0
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- The uncommitted `riff-hook-processor.py` working-tree diff contains anything beyond the stdin fallback and the `raw keys` log line described above.
- `IOHIDElementGetDevice` returns nil for live ring events (some macOS versions detach elements) — report rather than weakening the guard to a no-op.
- `make bar-install` relaunches RiffBar but the menu bar icon doesn't appear within 15s (check `/tmp/riff-bar.log`).
- Codesigning fails on either binary and `security unlock-keychain` needs a password.

## Maintenance notes

- Every LaunchAgent plist in this repo must use the `__INSTALL_DIR__` token + `sed` install pattern; reviewers should reject hardcoded absolute paths (they break the public "make install" story the README sells).
- The ring validation trusts the HID product name, which a sophisticated spoofer can also fake — this closes the accidental-device case (AUDIT.md #1's realistic risk), not a determined attacker; the AUDIT notes serial-number checking as a further step if ever needed.
- If Claude Code's hook JSON schema changes (`last_assistant_message` key), the processor degrades silently by design (exit 0 always) — check `/tmp/riff-hook-debug.log` first when narration stops.
