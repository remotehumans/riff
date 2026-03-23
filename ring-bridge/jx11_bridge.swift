import Foundation
import CoreGraphics
import IOKit
import IOKit.hid

// ABOUTME: JX-11 ring to keyboard bridge daemon for FluidVoice and Enter key.
// ABOUTME: Uses IOKit HID for device-specific ring detection, CGEvent tap to block defaults.

// --- Strategy ---
// IOKit HID Manager matches the ring by VendorID/ProductID (reliable across reconnects).
// IOKit input value callbacks fire on ring events and synthesize Option/Enter keys.
// CGEvent tap blocks the ring's default media key behavior using timing correlation:
// if IOKit just saw a ring event within 100ms, the next type-14 CGEvent gets blocked.

let kJX11VendorID: Int = 0x05AC
let kJX11ProductID: Int = 0x0220

// Timestamp of last IOKit ring event, used to correlate with CGEvent tap
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
    return elapsed < 0.15  // 150ms correlation window
}

// --- RingBridge ---

class RingBridge {
    var optionHeld = false
    var lastOptionTime: Date = .distantPast
    var lastEnterTime: Date = .distantPast

    var lastBackspaceTime: Date = .distantPast

    // Swipe detection via IOKit Digitizer X (page 0x1, usage 0x30)
    // Swipe right on ring (X decreases 700->100) = Enter
    // Swipe left on ring (X increases 300->900) = Backspace
    var swipeStartX: Int = 0
    var swipeMaxX: Int = 0
    var swipeMinX: Int = 1000
    var swipeActive = false

    func handleRingTap() {
        let now = Date()
        guard now.timeIntervalSince(lastOptionTime) > 0.3 else { return }
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

    var swipeGotFirstX = false

    func swipeStart() {
        swipeActive = true
        swipeGotFirstX = false
    }

    func swipeUpdate(x: Int) {
        guard swipeActive else { return }
        if !swipeGotFirstX {
            // Use first X value as the actual start position
            swipeStartX = x
            swipeMaxX = x
            swipeMinX = x
            swipeGotFirstX = true
        } else {
            if x > swipeMaxX { swipeMaxX = x }
            if x < swipeMinX { swipeMinX = x }
        }
    }

    func swipeEnd() {
        guard swipeActive else { return }
        swipeActive = false

        let now = Date()
        let rightDelta = swipeMaxX - swipeStartX
        let leftDelta = swipeStartX - swipeMinX

        // X increases (swipe left on ring) -> Backspace
        if rightDelta >= 400 {
            guard now.timeIntervalSince(lastBackspaceTime) > 0.5 else { return }
            lastBackspaceTime = now
            sendBackspace()
            return
        }

        // X decreases (swipe right on ring) -> Enter
        if leftDelta >= 400 {
            guard now.timeIntervalSince(lastEnterTime) > 0.5 else { return }
            lastEnterTime = now
            sendEnter()
        }
    }

    func sendBackspace() {
        let src = CGEventSource(stateID: .hidSystemState)
        // Delete/Backspace = keycode 51
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: true) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 51, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
        print("[\(ts())] BACKSPACE pressed")
    }

    func sendEnter() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let down = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: true) {
            down.post(tap: .cghidEventTap)
        }
        if let up = CGEvent(keyboardEventSource: src, virtualKey: 36, keyDown: false) {
            up.post(tap: .cghidEventTap)
        }
        print("[\(ts())] ENTER pressed")
    }

    func pressOption() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let e = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: true) {
            e.flags = .maskAlternate
            e.post(tap: .cghidEventTap)
        }
    }

    func releaseOption() {
        let src = CGEventSource(stateID: .hidSystemState)
        if let e = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: false) {
            e.flags = []
            e.post(tap: .cghidEventTap)
        }
    }

    func ts() -> String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return f.string(from: Date())
    }
}

func ts_global() -> String {
    let f = DateFormatter()
    f.dateFormat = "HH:mm:ss"
    return f.string(from: Date())
}

// --- Main ---

setbuf(stdout, nil)

let bridge = RingBridge()
bridge.releaseOption()

// --- IOKit HID Manager ---
// Matches ring by VendorID/ProductID. Registers input value callback on the
// specific device so we only ever process events from the actual ring.

let hidManager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
let matchDict: [String: Any] = [
    kIOHIDVendorIDKey: kJX11VendorID,
    kIOHIDProductIDKey: kJX11ProductID
]
IOHIDManagerSetDeviceMatching(hidManager, matchDict as CFDictionary)

// Shared IOKit input value callback for the ring device
let ringInputCallback: IOHIDValueCallback = { ctx, result, sender, value in
    let element = IOHIDValueGetElement(value)
    let usagePage = IOHIDElementGetUsagePage(element)
    let usage = IOHIDElementGetUsage(element)
    let intValue = IOHIDValueGetIntegerValue(value)

    let b = Unmanaged<RingBridge>.fromOpaque(ctx!).takeUnretainedValue()

    markRingIOKitEvent()

    // Consumer Control page (0x0C) - button press
    // Ring alternates between Vol Down (0xEA) and Vol Up (0xE9) on consecutive taps
    if usagePage == 0x0C && intValue > 0 {
        if usage == 0xE2 || usage == 0xEA || usage == 0xE9 {
            b.handleRingTap()
        }
    }

    // Digitizer page (0x0D) - In Range start/end for swipe detection
    if usagePage == 0x0D && usage == 0x32 {
        if intValue == 1 {
            b.swipeStart()
        } else {
            b.swipeEnd()
        }
    }

    // Generic Desktop page (0x1) - X coordinate updates during swipe
    if usagePage == 0x1 && usage == 0x30 {
        b.swipeUpdate(x: Int(intValue))
    }
}

func registerRingCallbacks(on device: IOHIDDevice) {
    IOHIDDeviceRegisterInputValueCallback(device, ringInputCallback,
        Unmanaged.passUnretained(bridge).toOpaque())
}

let hidMatchCallback: IOHIDDeviceCallback = { context, result, sender, device in
    print("[\(ts_global())] Ring connected via BLE")
    registerRingCallbacks(on: device)

    // Re-enable event tap on reconnect
    if let t = globalTap {
        CGEvent.tapEnable(tap: t, enable: true)
    }
}

let hidRemoveCallback: IOHIDDeviceCallback = { context, result, sender, device in
    print("[\(ts_global())] Ring disconnected")
}

IOHIDManagerRegisterDeviceMatchingCallback(hidManager, hidMatchCallback, nil)
IOHIDManagerRegisterDeviceRemovalCallback(hidManager, hidRemoveCallback, nil)
IOHIDManagerScheduleWithRunLoop(hidManager, CFRunLoopGetCurrent(), CFRunLoopMode.commonModes.rawValue)
IOHIDManagerOpen(hidManager, IOOptionBits(kIOHIDOptionsTypeNone))

// Register callbacks on already-connected devices
if let devices = IOHIDManagerCopyDevices(hidManager) as? Set<IOHIDDevice> {
    for device in devices {
        print("Ring already connected")
        registerRingCallbacks(on: device)
    }
}

// --- CGEvent Tap ---
// Only used to BLOCK default media key behavior from the ring.
// Does NOT identify the ring by field 87. Instead uses timing correlation
// with IOKit callbacks: if IOKit saw a ring event within 150ms, block it.

var globalTap: CFMachPort?
var globalRunLoopSource: CFRunLoopSource?

let mask: CGEventMask = (1 << 14) | (1 << CGEventType.scrollWheel.rawValue)

let callback: CGEventTapCallBack = { proxy, type, event, refcon in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let t = globalTap { CGEvent.tapEnable(tap: t, enable: true) }
        print("[\(ts_global())] Tap re-enabled")
        return Unmanaged.passUnretained(event)
    }

    // Block type-14 (media key) events that correlate with recent ring IOKit events
    if type.rawValue == 14 && isRecentRingIOKitEvent() {
        return nil
    }

    // Block scroll events that correlate with recent ring IOKit events
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
        eventsOfInterest: mask,
        callback: callback,
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
        if createAndInstallTap() { print("[\(ts_global())] Health: tap reinstalled") }
        return
    }
    if !CGEvent.tapIsEnabled(tap: tap) {
        CGEvent.tapEnable(tap: tap, enable: true)
        if !CGEvent.tapIsEnabled(tap: tap) {
            _ = createAndInstallTap()
            print("[\(ts_global())] Health: tap reinstalled")
        } else {
            print("[\(ts_global())] Health: tap re-enabled")
        }
    }
}
healthTimer.resume()

// --- Banner ---

print("========================================")
print("  JX-11 Ring -> FluidVoice Bridge")
print("========================================")
print("Tap ring: toggle Left Option (push-to-talk)")
print("  1st tap = START recording")
print("  2nd tap = STOP recording")
print("Swipe right: Enter key (submit messages)")
print("Swipe left: Backspace/Delete")
print("Mute blocked. Keyboard volume keys unaffected.")
print("")
print("Device detection: IOKit HID (VendorID/ProductID)")
print("Health check: every 5s")
print("Running... (Ctrl+C to stop)")

// --- Clean Shutdown ---

func cleanShutdown(_ sig: Int32) {
    let src = CGEventSource(stateID: .hidSystemState)
    if let e = CGEvent(keyboardEventSource: src, virtualKey: 58, keyDown: false) {
        e.flags = []
        e.post(tap: .cghidEventTap)
    }
    print("\nBridge stopped. Option key released.")
    exit(0)
}

signal(SIGINT, cleanShutdown)
signal(SIGTERM, cleanShutdown)

CFRunLoopRun()
