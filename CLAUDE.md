# Voice AI

Monorepo for voice AI components — smart ring input, transcription, and voice-driven workflows.

## Components

### ring-bridge
macOS daemon that bridges a JX-11 smart ring (BLE HID) to keyboard events for voice AI interaction.
- **Tap**: Toggle Left Option key (FluidVoice push-to-talk)
- **Swipe right**: Enter key (submit messages)
- **Swipe left**: Backspace/Delete

Uses IOKit HID Manager for device-specific detection (VendorID/ProductID) and CGEvent tap to block default media key behavior.

## Build & Run

### ring-bridge
```bash
cd ring-bridge
swiftc jx11_bridge.swift -o jx11-bridge -framework CoreGraphics -framework IOKit
./jx11-bridge
```

Requires macOS Accessibility permission. Signed with Apple Development certificate for stable permissions across recompiles.

LaunchAgent: `~/Library/LaunchAgents/co.remotehumans.jx11-bridge.plist`
