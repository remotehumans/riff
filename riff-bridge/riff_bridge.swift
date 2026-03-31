import Foundation
import CoreGraphics
import IOKit
import IOKit.hid

// ABOUTME: Smart ring to keyboard bridge daemon for voice AI interaction.
// ABOUTME: Maps tap, swipes (X/Y axis), and short touch to keyboard/scroll events.
// ABOUTME: Supports multiple ring models (JX-11, JX-13) via device registry.

// --- Strategy ---
// IOKit HID Manager matches the ring by VendorID/ProductID (reliable across reconnects).
// IOKit input value callbacks fire on ring events and synthesize Option/Enter keys.
// CGEvent tap blocks the ring's default media key behavior using timing correlation:
// if IOKit just saw a ring event within 150ms, the next type-14 CGEvent gets blocked.
//
// Threading: All callbacks and timers are scheduled on the main CFRunLoop.
// RingBridge state is NOT thread-safe beyond this single-thread contract.
// Only lastRingIOKitEventTime uses os_unfair_lock (shared between IOKit and CGEvent callbacks).

// --- Supported Devices ---
// Add new rings here. Run `system_profiler SPBluetoothDataType` to find Vendor/Product IDs.

struct RingDevice {
    let name: String
    let vendorID: Int
    let productID: Int
}

let supportedRings: [RingDevice] = [
    RingDevice(name: "JX-11", vendorID: 0x05AC, productID: 0x0220),
    RingDevice(name: "JX-13", vendorID: 0x248A, productID: 0x8251),
    // To add a new ring:
    // 1. Pair it via Bluetooth
    // 2. Run: system_profiler SPBluetoothDataType | grep -A 5 "YourRing"
    // 3. Add: RingDevice(name: "YourRing", vendorID: 0xXXXX, productID: 0xYYYY),
]

// --- Constants ---

// HID usage pages
let kConsumerControlPage: UInt32 = 0x0C
let kDigitizerPage: UInt32 = 0x0D
let kGenericDesktopPage: UInt32 = 0x01

// HID usage IDs — Consumer Control
let kUsageMute: UInt32 = 0xE2
let kUsageVolDown: UInt32 = 0xEA
let kUsageVolUp: UInt32 = 0xE9

// HID usage IDs — Digitizer
let kUsageInRange: UInt32 = 0x32

// HID usage IDs — Generic Desktop
let kUsageX: UInt32 = 0x30
let kUsageY: UInt32 = 0x31

// macOS virtual keycodes
let kKeyCodeOption: CGKeyCode = 61  // Right Option key (58 = Left Option)
let kKeyCodeReturn: CGKeyCode = 36
let kKeyCodeDelete: CGKeyCode = 51
let kKeyCodeEscape: CGKeyCode = 53

// Timing thresholds (seconds)
let kTapDebounce: TimeInterval = 0.6  // JX-13 sends duplicate events per tap; 0.6s filters the second
let kSwipeDebounce: TimeInterval = 0.5
let kCorrelationWindow: TimeInterval = 0.15

// Swipe gesture threshold (HID coordinate units, applies to both X and Y)
let kSwipeThreshold: Int = 400

// HID coordinate valid range (for input clamping, applies to both X and Y)
let kSwipeCoordMin: Int = 0
let kSwipeCoordMax: Int = 1023

// Short touch detection: max duration (seconds) and max movement to count as a tap (not swipe)
let kShortTouchMaxDuration: TimeInterval = 0.3
let kShortTouchMaxMovement: Int = 100
let kEscapeDebounce: TimeInterval = 0.5

// Scroll lines per continuous scroll event during Y-axis swipe
let kScrollAmount: Int32 = 3
// Minimum Y coordinate change between scroll events (lower = more frequent, smoother)
let kScrollStepThreshold: Int = 15

// CGEvent type for system-defined (media) keys
let kCGEventTypeSystemDefined: UInt32 = 14

// --- Timestamp Formatter ---

private let tsFormatter: DateFormatter = {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f
}()

func ts() -> String { tsFormatter.string(from: Date()) }

// --- Timing Correlation ---
// Shared between IOKit callbacks and CGEvent tap via os_unfair_lock.

var lastRingIOKitEventTime: Date = .distantPast
var ringIOKitLock = os_unfair_lock()


func markRingIOKitEvent() {
    os_unfair_lock_lock(&ringIOKitLock)
    lastRingIOKitEventTime = Date()
    os_unfair_lock_unlock(&ringIOKitLock)
}

func isRecentRingIOKitEvent() -> Bool {
    os_unfair_lock_lock(&ringIOKitLock)
    let elapsed = Date().timeIntervalSince(lastRingIOKitEventTime)
    os_unfair_lock_unlock(&ringIOKitLock)
    return elapsed < kCorrelationWindow
}

func clearRingIOKitEvent() {
    os_unfair_lock_lock(&ringIOKitLock)
    lastRingIOKitEventTime = .distantPast
    os_unfair_lock_unlock(&ringIOKitLock)
}

// --- RingBridge ---

class RingBridge {
    var optionHeld = false
    var lastOptionTime: Date = .distantPast
    var lastEnterTime: Date = .distantPast
    var lastBackspaceTime: Date = .distantPast

    var lastEscapeTime: Date = .distantPast
    var lastScrollTime: Date = .distantPast

    // Swipe detection via IOKit Digitizer (page 0x01)
    // X-axis (usage 0x30): swipe right on ring (X decreases) = Enter, swipe left (X increases) = Backspace
    // Y-axis (usage 0x31): swipe down on ring (Y increases to 1200) = scroll down, swipe up (Y decreases to 0) = scroll up
    // Note: physical direction on ring surface is opposite to coordinate direction
    var swipeStartX: Int = 0
    var swipeMaxX: Int = 0
    var swipeMinX: Int = 0
    var swipeStartY: Int = 0
    var swipeMaxY: Int = 0
    var swipeMinY: Int = 0
    var swipeActive = false
    var swipeGotFirstX = false
    var swipeGotFirstY = false
    var swipeStartTime: Date = .distantPast
    // Continuous scroll: last Y value that triggered a scroll event
    var lastScrollY: Int = 0

    func handleRingTap() {
        let now = Date()
        guard now.timeIntervalSince(lastOptionTime) > kTapDebounce else { return }
        lastOptionTime = now

        if optionHeld {
            releaseOption()
            optionHeld = false
            print("[\(ts())] STOP recording (Option released)")
        } else {
            pressOption()
            optionHeld = true
            print("[\(ts())] START recording (Option pressed)")
        }
    }

    func swipeStart() {
        swipeActive = true
        swipeGotFirstX = false
        swipeGotFirstY = false
        swipeStartX = 0
        swipeMaxX = 0
        swipeMinX = 0
        swipeStartY = 0
        swipeMaxY = 0
        swipeMinY = 0
        lastScrollY = 0
        swipeStartTime = Date()
    }

    func swipeUpdateX(_ x: Int) {
        guard swipeActive else { return }
        let clamped = max(kSwipeCoordMin, min(kSwipeCoordMax, x))
        if !swipeGotFirstX {
            swipeStartX = clamped
            swipeMaxX = clamped
            swipeMinX = clamped
            swipeGotFirstX = true
        } else {
            if clamped > swipeMaxX { swipeMaxX = clamped }
            if clamped < swipeMinX { swipeMinX = clamped }
        }
    }

    func swipeUpdateY(_ y: Int) {
        guard swipeActive else { return }
        let clamped = max(kSwipeCoordMin, min(kSwipeCoordMax, y))
        if !swipeGotFirstY {
            swipeStartY = clamped
            swipeMaxY = clamped
            swipeMinY = clamped
            lastScrollY = clamped
            swipeGotFirstY = true
        } else {
            if clamped > swipeMaxY { swipeMaxY = clamped }
            if clamped < swipeMinY { swipeMinY = clamped }

            // Fire continuous scroll events as Y changes during the swipe
            let delta = clamped - lastScrollY
            if abs(delta) >= kScrollStepThreshold {
                // Y increases = scroll down (direction -1), Y decreases = scroll up (direction 1)
                let direction: Int32 = delta > 0 ? -1 : 1
                sendScroll(direction: direction)
                lastScrollY = clamped
            }
        }
    }

    func swipeEnd() {
        guard swipeActive else { return }
        swipeActive = false

        let now = Date()
        let duration = now.timeIntervalSince(swipeStartTime)

        let xIncreaseDelta = swipeMaxX - swipeStartX
        let xDecreaseDelta = swipeStartX - swipeMinX
        let yIncreaseDelta = swipeMaxY - swipeStartY
        let yDecreaseDelta = swipeStartY - swipeMinY

        let maxXMovement = max(xIncreaseDelta, xDecreaseDelta)
        let maxYMovement = max(yIncreaseDelta, yDecreaseDelta)

        // Short touch with no significant movement -> Escape + Riff interrupt
        if duration < kShortTouchMaxDuration && maxXMovement < kShortTouchMaxMovement && maxYMovement < kShortTouchMaxMovement {
            guard now.timeIntervalSince(lastEscapeTime) > kEscapeDebounce else { return }
            lastEscapeTime = now
            sendKey(kKeyCodeEscape, name: "ESCAPE")
            interruptRiff()
            return
        }

        // Y-axis scrolling is handled continuously in swipeUpdateY, so only
        // process X-axis swipes (Enter/Backspace) at swipeEnd.

        // X increases (swipe left on ring) -> Backspace
        if xIncreaseDelta >= kSwipeThreshold {
            guard now.timeIntervalSince(lastBackspaceTime) > kSwipeDebounce else { return }
            lastBackspaceTime = now
            sendKey(kKeyCodeDelete, name: "BACKSPACE")
            return
        }
        // X decreases (swipe right on ring) -> Enter
        if xDecreaseDelta >= kSwipeThreshold {
            guard now.timeIntervalSince(lastEnterTime) > kSwipeDebounce else { return }
            lastEnterTime = now
            sendKey(kKeyCodeReturn, name: "ENTER")
        }
    }

    func sendScroll(direction: Int32) {
        // direction: 1 = scroll up, -1 = scroll down
        // Temporarily reset the ring event timestamp so our CGEvent tap doesn't
        // correlate this scroll with a ring event and block it.
        clearRingIOKitEvent()
        let src = CGEventSource(stateID: .hidSystemState)
        if let scrollEvent = CGEvent(scrollWheelEvent2Source: src, units: .line, wheelCount: 1, wheel1: direction * kScrollAmount, wheel2: 0, wheel3: 0) {
            scrollEvent.post(tap: .cghidEventTap)
        }
        let label = direction > 0 ? "SCROLL UP" : "SCROLL DOWN"
        print("[\(ts())] \(label)")
    }

    func sendKey(_ keyCode: CGKeyCode, name: String) {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: true) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: keyCode, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
        print("[\(ts())] \(name) pressed")
    }

    func interruptRiff() {
        // Send interrupt to Riff voice daemon via Unix socket (non-blocking, fire-and-forget)
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        task.arguments = ["-c", """
            import socket, json
            try:
                s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
                s.settimeout(1)
                s.connect('/tmp/riff.sock')
                s.send(json.dumps({"type": "interrupt"}).encode() + b"\\n")
                s.recv(1024)
                s.close()
            except:
                pass
            """]
        task.standardOutput = FileHandle.nullDevice
        task.standardError = FileHandle.nullDevice
        do {
            try task.run()
            print("[\(ts())] RIFF interrupt sent")
        } catch {
            // Riff daemon might not be running - that's fine
        }
    }

    func pressOption() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let e = CGEvent(keyboardEventSource: src, virtualKey: kKeyCodeOption, keyDown: true) {
            e.flags = .maskAlternate
            e.post(tap: .cghidEventTap)
        }
    }

    func releaseOption() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let e = CGEvent(keyboardEventSource: src, virtualKey: kKeyCodeOption, keyDown: false) {
            e.flags = []
            e.post(tap: .cghidEventTap)
        }
    }
}

// --- Device Selection ---
// Match the first supported ring found, or accept --ring <name> argument.

func selectRing() -> RingDevice? {
    // Check for --ring argument
    let args = CommandLine.arguments
    if let idx = args.firstIndex(of: "--ring"), idx + 1 < args.count {
        let requested = args[idx + 1]
        if let ring = supportedRings.first(where: { $0.name.lowercased() == requested.lowercased() }) {
            return ring
        }
        print("ERROR: Unknown ring '\(requested)'. Supported: \(supportedRings.map(\.name).joined(separator: ", "))")
        exit(1)
    }

    // Auto-detect: try each supported ring and see which is connected
    let tempManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
    defer { IOHIDManagerClose(tempManager, IOOptionBits(kIOHIDOptionsTypeNone)) }

    for ring in supportedRings {
        let match: [String: Any] = [
            kIOHIDVendorIDKey: ring.vendorID,
            kIOHIDProductIDKey: ring.productID
        ]
        IOHIDManagerSetDeviceMatching(tempManager, match as CFDictionary)
        IOHIDManagerScheduleWithRunLoop(tempManager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
        IOHIDManagerOpen(tempManager, IOOptionBits(kIOHIDOptionsTypeNone))

        if let devices = IOHIDManagerCopyDevices(tempManager) as? Set<IOHIDDevice>, !devices.isEmpty {
            IOHIDManagerClose(tempManager, IOOptionBits(kIOHIDOptionsTypeNone))
            return ring
        }
        IOHIDManagerClose(tempManager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    return nil
}

// --- Main ---
// All callbacks and timers are scheduled on the main CFRunLoop.

setbuf(stdout, nil)

// Handle --list flag
if CommandLine.arguments.contains("--list") {
    print("Supported rings:")
    for ring in supportedRings {
        print("  \(ring.name)  VendorID: \(String(format: "0x%04X", ring.vendorID))  ProductID: \(String(format: "0x%04X", ring.productID))")
    }
    exit(0)
}

guard let selectedRing = selectRing() else {
    print("ERROR: No supported ring detected.")
    print("Supported rings:")
    for ring in supportedRings {
        print("  \(ring.name)  VendorID: \(String(format: "0x%04X", ring.vendorID))  ProductID: \(String(format: "0x%04X", ring.productID))")
    }
    print("")
    print("Make sure your ring is paired in Bluetooth settings.")
    print("To force a specific ring: riff-bridge --ring JX-13")
    print("To find your ring's IDs: system_profiler SPBluetoothDataType | grep -A 5 \"YourRing\"")
    exit(1)
}

print("[\(ts())] Selected ring: \(selectedRing.name) (VendorID: \(String(format: "0x%04X", selectedRing.vendorID)), ProductID: \(String(format: "0x%04X", selectedRing.productID)))")

let bridge = RingBridge()
bridge.releaseOption()

// --- IOKit HID Manager ---
// Matches ring by VendorID/ProductID. Registers input value callback on the
// specific device so we only ever process events from the actual ring.

let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matchDict: [String: Any] = [
    kIOHIDVendorIDKey: selectedRing.vendorID,
    kIOHIDProductIDKey: selectedRing.productID
]
IOHIDManagerSetDeviceMatching(hidManager, matchDict as CFDictionary)

// IOKit input value callback for the ring device
let ringInputCallback: IOHIDValueCallback = { ctx, result, sender, value in
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)

    guard let ctx = ctx else { return }
    let b = Unmanaged<RingBridge>.fromOpaque(ctx).takeUnretainedValue()

    // Mark timing for CGEvent correlation ONLY on Consumer Control events.
    // Digitizer/coordinate events during swipes must NOT mark, otherwise trailing
    // IOKit events race with clearRingIOKitEvent() and block our synthetic scrolls.
    if usagePage == kConsumerControlPage {
        markRingIOKitEvent()
    }

    // Consumer Control page — button press
    // Ring alternates between Vol Down and Vol Up on consecutive taps
    if usagePage == kConsumerControlPage && intValue > 0 {
        if usage == kUsageMute || usage == kUsageVolDown || usage == kUsageVolUp {
            b.handleRingTap()
        }
    }

    // Digitizer page — In Range start/end for swipe detection
    if usagePage == kDigitizerPage && usage == kUsageInRange {
        if intValue == 1 {
            b.swipeStart()
        } else {
            b.swipeEnd()
        }
    }

    // Generic Desktop page — X and Y coordinate updates during swipe
    if usagePage == kGenericDesktopPage && usage == kUsageX {
        b.swipeUpdateX(Int(intValue))
    }
    if usagePage == kGenericDesktopPage && usage == kUsageY {
        b.swipeUpdateY(Int(intValue))
    }
}

// Register input callback at manager level (not per-device) so we capture events
// from ALL HID interfaces the ring exposes. The ring has separate Consumer Control
// and Digitizer interfaces — per-device registration only catches one.
IOHIDManagerRegisterInputValueCallback(hidManager, ringInputCallback,
    Unmanaged.passUnretained(bridge).toOpaque())

let hidMatchCallback: IOHIDDeviceCallback = { context, result, sender, device in
    let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
    let serial = IOHIDDeviceGetProperty(device, kIOHIDSerialNumberKey as CFString) as? String ?? "none"
    let manufacturer = IOHIDDeviceGetProperty(device, kIOHIDManufacturerKey as CFString) as? String ?? "unknown"
    print("[\(ts())] Ring connected — name: \(name), serial: \(serial), manufacturer: \(manufacturer)")

    // Re-enable event tap on reconnect
    if let t = globalTap {
        CGEvent.tapEnable(tap: t, enable: true)
    }
}

let hidRemoveCallback: IOHIDDeviceCallback = { context, result, sender, device in
    print("[\(ts())] Ring disconnected")
}

IOHIDManagerRegisterDeviceMatchingCallback(hidManager, hidMatchCallback, nil)
IOHIDManagerRegisterDeviceRemovalCallback(hidManager, hidRemoveCallback, nil)
IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)

let hidOpenResult = IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))
if hidOpenResult != kIOReturnSuccess {
    print("ERROR: IOHIDManagerOpen failed with code \(hidOpenResult)")
    print("Check Input Monitoring permissions in System Settings > Privacy & Security")
    exit(1)
}

// Log already-connected devices
if let devices = IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice> {
    for device in devices {
        let name = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) as? String ?? "unknown"
        print("[\(ts())] Ring already connected — \(name)")
    }
}

// --- CGEvent Tap ---
// Only used to BLOCK default media key behavior from the ring.
// Does NOT identify the ring by field 87. Instead uses timing correlation
// with IOKit callbacks: if IOKit saw a ring event within 150ms, block it.

var globalTap: CFMachPort?
var globalRunLoopSource: CFRunLoopSource?

let cgEventMask: CGEventMask = (1 << kCGEventTypeSystemDefined) | (1 << CGEventType.scrollWheel.rawValue)

let cgEventTapCallback: CGEventTapCallBack = { proxy, type, event, refcon in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = globalTap { CGEvent.tapEnable(tap: t, enable: true) }
        print("[\(ts())] Tap re-enabled")
        return Unmanaged.passUnretained(event)
    }

    // Block system-defined (media key) events that correlate with recent ring IOKit events
    if type.rawValue == kCGEventTypeSystemDefined && isRecentRingIOKitEvent() {
        return nil
    }

    // Block scroll events that correlate with recent ring IOKit events.
    // Our synthetic scroll events clear the timestamp before posting so they pass through.
    if type == .scrollWheel && isRecentRingIOKitEvent() {
        return nil
    }

    return Unmanaged.passUnretained(event)
}

func createAndInstallTap() -> Bool {
    if let oldSource = globalRunLoopSource {
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), oldSource, .commonModes)
    }
    globalTap = nil
    globalRunLoopSource = nil

    guard let tap = CGEvent.tapCreate(
        tap: .cgSessionEventTap,
        place: .headInsertEventTap,
        options: .defaultTap,
        eventsOfInterest: cgEventMask,
        callback: cgEventTapCallback,
        userInfo: nil
    ) else {
        return false
    }

    globalTap = tap
    globalRunLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
    CFRunLoopAddSource(CFRunLoopGetCurrent(), globalRunLoopSource, .commonModes)
    CGEvent.tapEnable(tap: tap, enable: true)
    return true
}

guard createAndInstallTap() else {
    print("ERROR: Need Accessibility permission.")
    print("System Settings > Privacy & Security > Accessibility")
    exit(1)
}

// Health check timer
let healthTimer = DispatchSource.makeTimerSource(queue: .main)
healthTimer.schedule(deadline: .now() + 5, repeating: 5.0)
healthTimer.setEventHandler {
    guard let tap = globalTap else {
        if createAndInstallTap() { print("[\(ts())] Health: tap reinstalled") }
        return
    }
    if !CGEvent.tapIsEnabled(tap: tap) {
        CGEvent.tapEnable(tap: tap, enable: true)
        if !CGEvent.tapIsEnabled(tap: tap) {
            _ = createAndInstallTap()
            print("[\(ts())] Health: tap reinstalled")
        } else {
            print("[\(ts())] Health: tap re-enabled")
        }
    }
}
healthTimer.resume()

// --- Banner ---

print("========================================")
print("  Riff Bridge — \(selectedRing.name)")
print("========================================")
print("Tap ring:    toggle Left Option (push-to-talk)")
print("  1st tap  = START recording")
print("  2nd tap  = STOP recording")
print("Swipe right: Enter (submit messages)")
print("Swipe left:  Backspace/Delete")
print("Swipe up:    Scroll up")
print("Swipe down:  Scroll down")
print("Short touch: Escape (interrupt agent)")
print("Mute blocked. Keyboard volume keys unaffected.")
print("")
print("Usage: riff-bridge [--ring JX-11|JX-13] [--list]")
print("Health check: every 5s")
print("Running... (Ctrl+C to stop)")

// --- Clean Shutdown ---
// Uses DispatchSource signal handlers instead of raw signal() to avoid
// calling non-async-signal-safe functions from signal context.

let sigintSource = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
let sigtermSource = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)

func performShutdown() {
    bridge.releaseOption()
    print("\nBridge stopped. Option key released.")
    exit(0)
}

sigintSource.setEventHandler { performShutdown() }
sigtermSource.setEventHandler { performShutdown() }

// Ignore default signal handling so DispatchSource receives the signals
signal(SIGINT, SIG_IGN)
signal(SIGTERM, SIG_IGN)

sigintSource.resume()
sigtermSource.resume()

CFRunLoopRun()
