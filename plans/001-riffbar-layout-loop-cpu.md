# Plan 001: Eliminate the RiffBar SwiftUI layout feedback loop (96% CPU, 1.1GB RAM at idle)

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 56bd58c..HEAD -- riff-voice/RiffBar/`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MED (UI restructure; behaviour must be verified manually on a live Mac)
- **Depends on**: none
- **Category**: perf
- **Planned at**: commit `56bd58c`, 2026-06-12

## Why this matters

RiffBar (the menu bar app for the Riff voice narrator) consumes ~96% of one CPU core and ~1.1GB of RAM **while idle, with the popover closed**. The user experiences this as: clicking the menu bar icon takes seconds to show the popover, and toggling Enabled/Disabled is sluggish — the main thread is saturated with layout work so UI events queue up behind it. Two previous commits (`be85d2e`, `4f86f4d`, `56bd58c`) attempted CPU fixes via config-reload caching and `updatePublishedValue` equality guards; the live process proves the loop is still present, so the root cause is not data churn — it is a layout invalidation cycle.

Diagnostic evidence captured on 2026-06-12 from the live process (`ps aux`):

```
elliott  939  96.1  6.8  ...  /Users/elliott/Documents/AI Projects_local/voice-ai/riff-voice/RiffBar/RiffBar
```

A 3-second `sample 939` showed **995 of 1216 main-thread samples** inside this cycle, repeating every display refresh:

```
NSDisplayCycleFlush
→ -[NSWindow updateConstraintsIfNeeded]
→ NSHostingView.updateConstraints()
→ NSHostingView.updateWindowContentSizeExtremaIfNecessary()
→ NSHostingView.minSize() → ViewGraph.sizeThatFits(_:)
→ AG::Graph::update_attribute → DynamicBody.updateValue → ViewBodyAccessor.updateBody → Button.body.getter
```

That is a classic SwiftUI-on-AppKit layout feedback loop: computing the hosting view's min/max size dirties the view graph, which schedules another constraints pass, every frame, forever. The 1.1GB RSS is the side effect of this churn. Fixing this fixes the slowness complaint *and* the resource complaint in one move.

## Current state

- `riff-voice/RiffBar/RiffBarApp.swift` — app entry point; `MenuBarExtra` with `.window` style hosts `PopoverView`. The whole file (24 lines):

```swift
// riff-voice/RiffBar/RiffBarApp.swift:6-24
@main
struct RiffBarApp: App {
    @StateObject private var daemon = DaemonConnection()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(daemon: daemon)
                .onAppear { daemon.popoverOpened() }
                .onDisappear { daemon.popoverClosed() }
        } label: {
            Image(systemName: daemon.speaking ? "speaker.wave.2.fill" : "speaker.wave.2")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(daemon: daemon)
        }
    }
}
```

- `riff-voice/RiffBar/PopoverView.swift` — the popover content. Root layout (lines 9–47): a `VStack` ending in `.padding(16).frame(width: 420).preferredColorScheme(.dark)`. Width is fixed but **height is unconstrained and content-dependent**: a conditional `queueIndicator` (line 21), a sessions `ScrollView` with `.frame(maxHeight: 180)` (lines 234–255), and conditional rows. Variable intrinsic height + `MenuBarExtra(.window)`'s min-size negotiation is the prime suspect for the `minSize()` loop.
- `riff-voice/RiffBar/DaemonConnection.swift` — `ObservableObject` polled state; polls daemon status every 5s idle / 2s while popover open. Already guards publishes behind `updatePublishedValue` (lines 422–425), so data-driven re-render churn has been addressed — don't redo that work.
- `riff-voice/RiffBar/SettingsView.swift`, `SessionRow.swift` — settings window and row component, both plain SwiftUI.
- `riff-voice/RiffBar/build.sh` — builds with `swiftc` (not Xcode) and codesigns with identity "Apple Development".
- Installed LaunchAgent: `~/Library/LaunchAgents/co.remotehumans.riff-bar.plist` runs the compiled binary at `riff-voice/RiffBar/RiffBar`, logs to `/tmp/riff-bar.log`, `KeepAlive=false`.

Repo conventions: every source file starts with two `// ABOUTME:` comment lines — preserve them and add them to any new file. Code style: plain SwiftUI, no external dependencies, single-target compiled by `build.sh`.

## Commands you will need

| Purpose | Command | Expected on success |
|---|---|---|
| Build | `cd "riff-voice/RiffBar" && bash build.sh` | "RiffBar built successfully." |
| Restart app | `launchctl bootout gui/$(id -u)/co.remotehumans.riff-bar 2>/dev/null; launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/co.remotehumans.riff-bar.plist` | exit 0; icon appears in menu bar |
| Measure CPU | `pid=$(pgrep -x RiffBar) && top -l 12 -s 5 -pid $pid -stats pid,cpu,mem \| grep -E "^$pid"` (60s of 5s samples) | see per-step targets |
| Find hotspot | `sample $(pgrep -x RiffBar) 3 -file /tmp/riffbar-sample.txt && grep -c "updateConstraints" /tmp/riffbar-sample.txt` | see per-step targets |
| App log | `tail -20 /tmp/riff-bar.log` | no crash/spew |

Note: `build.sh` codesigns with "Apple Development". If signing fails with a keychain error, run `security unlock-keychain` — and if that needs a password you don't have, that's a STOP condition.

## Scope

**In scope** (the only files you should modify):
- `riff-voice/RiffBar/RiffBarApp.swift`
- `riff-voice/RiffBar/PopoverView.swift`
- `riff-voice/RiffBar/DaemonConnection.swift` (only if the chosen fix needs a visibility flag)
- New file `riff-voice/RiffBar/StatusItemController.swift` (only if Step 4's fallback is needed)
- `riff-voice/RiffBar/build.sh` (only to add the new file to the compile list, if created)

**Out of scope** (do NOT touch, even though they look related):
- `riff-voice/src/riff/` — the Python daemon. Daemon responsiveness is plan 002.
- `riff-voice/RiffBar/co.remotehumans.riff-bar.plist` and the Makefile — packaging fixes are plan 004.
- The socket protocol or polling cadence in `DaemonConnection.swift` — plan 002 touches the request pipeline; avoid merge pain.
- `SettingsView.swift`, `SessionRow.swift` — unless Step 1 proves the loop originates there (then STOP and report instead).

## Git workflow

- Branch: `advisor/001-riffbar-layout-loop`
- Commit per step, conventional-commit style matching repo history, e.g. `perf(riff-bar): stop layout feedback loop by fixing popover content size`
- Do NOT push or open a PR unless the operator instructed it.

## Steps

### Step 1: Reproduce and pin down the looping window

Build and restart the current code unchanged. With the popover **closed**, capture baseline CPU and a 3s sample. Confirm the loop signature (`updateConstraints` / `updateWindowContentSizeExtremaIfNecessary` dominating). Then open the popover once, close it, and re-measure — note whether the loop exists from launch or only after first open. Record both numbers in the commit message of the next step.

**Verify**: `sample $(pgrep -x RiffBar) 3 -file /tmp/riffbar-base.txt && grep -c "updateWindowContentSizeExtremaIfNecessary" /tmp/riffbar-base.txt` → count > 0 (loop reproduced). If count is 0 and CPU is already < 5%, STOP — the environment differs from the one audited.

### Step 2: Fix attempt A — give the popover content a fully fixed size

In `PopoverView.swift`, change the root modifier `.frame(width: 420)` to a fixed size `.frame(width: 420, height: 560, alignment: .top)` and make inner content top-aligned so shorter content doesn't stretch. Remove size-feedback ambiguity: replace the sessions `ScrollView`'s `.frame(maxHeight: 180)` with a fixed `.frame(height: 180)`. The popover becomes constant-size; `minSize()` has nothing to renegotiate.

Build, restart, repeat the Step 1 measurement (both before and after opening the popover once).

**Verify**: `top -l 12 -s 5 -pid $(pgrep -x RiffBar) -stats cpu | tail -10` → every sample below 2.0% with popover closed. If still looping, continue to Step 3 (keep the fixed-size change; it is harmless).

### Step 3: Fix attempt B — stop rendering popover content while hidden

`MenuBarExtra(.window)` keeps its `NSHostingView` alive while hidden. Gate the content on visibility: add `@Published var popoverVisible = false` to `DaemonConnection` (set true in `popoverOpened()`, false in `popoverClosed()` — both already exist at `DaemonConnection.swift:44-54`). In `RiffBarApp.swift`, wrap the content:

```swift
MenuBarExtra {
    PopoverContentGate(daemon: daemon)
} label: { ... }
```

where `PopoverContentGate` is a small view that renders `PopoverView(daemon: daemon)` and uses `.onAppear`/`.onDisappear` to flip the flag — but renders `Color.clear.frame(width: 1, height: 1)` in place of the heavy body when not visible. (onAppear fires when the popover window shows; that mounts the real content one frame later via the flag.)

**Verify**: same `top` command → all samples < 2.0% with popover closed; open the popover and confirm it still shows live status within ~1 second, then close and confirm CPU returns < 2.0% within 10 seconds.

### Step 4: Fallback — replace MenuBarExtra with NSStatusItem + NSPopover (only if Steps 2–3 both failed)

If the loop survives both fixes, the bug is inside `MenuBarExtra(.window)` itself. Create `riff-voice/RiffBar/StatusItemController.swift` (with ABOUTME header lines): an `NSApplicationDelegateAdaptor`-based `NSStatusItem` whose button toggles an `NSPopover` containing `NSHostingController(rootView: PopoverView(daemon: daemon))`, **created on show and torn down on close** (`popover.contentViewController = nil` on close). Keep the `Settings` scene as is. Update the icon on `daemon.$speaking` via a Combine sink. Add the new file to the `swiftc` invocation in `build.sh`.

**Verify**: build succeeds; `top` samples < 2.0% closed; popover opens with full controls; icon still switches between `speaker.wave.2` and `speaker.wave.2.fill` while speaking (test with `riff-say "testing one two three"`).

### Step 5: Memory check and 10-minute soak

Restart the app, leave it idle 10 minutes (popover closed), opening/closing the popover 3 times during that window.

**Verify**: `ps -o rss= -p $(pgrep -x RiffBar)` → under 153600 (150MB in KB); CPU samples still < 2.0%.

## Test plan

There is no automated UI test infrastructure in this repo (compiled via `swiftc`, no Xcode project, no XCTest target) — verification for this plan is the measurement gates above. Do not introduce a test framework here; that is recorded as a deferred item in `plans/README.md`.

Manual regression checklist (all must work after the fix):
- Toggle Enabled off → `riff-ctl status` shows `"enabled": false`.
- Speed slider change → `riff-ctl status` shows the new speed.
- Interrupt button stops speech started with `riff-say "a fairly long sentence to give you time to press the button"`.
- Sessions list renders and a voice can be changed from the dropdown.
- Settings window opens from the popover footer.

## Done criteria

Machine-checkable. ALL must hold:

- [ ] `bash riff-voice/RiffBar/build.sh` exits 0
- [ ] With popover closed, 12×5s `top` samples all show CPU < 2.0%
- [ ] After opening/closing the popover 3×, CPU returns < 2.0% within 10s
- [ ] `ps -o rss= -p $(pgrep -x RiffBar)` < 153600 after a 10-minute soak
- [ ] `sample $(pgrep -x RiffBar) 3` no longer shows `updateWindowContentSizeExtremaIfNecessary` as the dominant frame (grep count < 10)
- [ ] Manual regression checklist above passes
- [ ] No files outside the in-scope list are modified (`git status`)
- [ ] `plans/README.md` status row updated

## STOP conditions

Stop and report back (do not improvise) if:

- Step 1 cannot reproduce the loop (CPU already < 5% idle) — the audited environment has drifted.
- The sample in Step 1 shows the hot window is the **Settings** window or the daemon, not the popover hosting view.
- Codesigning fails and `security unlock-keychain` requires a password.
- Steps 2, 3 AND 4 all fail to bring idle CPU under 2% — report the post-fix sample output instead of trying further restructures.
- The fix appears to require changing the daemon protocol or files in `riff-voice/src/`.

## Maintenance notes

- Any future conditional content added to `PopoverView` (new rows, banners) must not reintroduce variable intrinsic height if Step 2's fixed-size fix is what landed — add content inside the fixed frame.
- If Step 4's AppKit fallback landed, `MenuBarExtra` should not be reintroduced without re-running the CPU soak test; reviewers should scrutinise popover teardown (content view controller must be released on close).
- Deferred: the menu bar icon could also show queue depth; do it after this plan so the soak baseline stays clean.
