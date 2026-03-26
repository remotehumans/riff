// ABOUTME: SwiftUI macOS menu bar app entry point for Riff voice narrator.
// ABOUTME: Presents a MenuBarExtra popover with daemon status and controls.

import SwiftUI

@main
struct RiffBarApp: App {
    @StateObject private var daemon = DaemonConnection()

    var body: some Scene {
        MenuBarExtra {
            PopoverView(daemon: daemon)
        } label: {
            Image(systemName: daemon.speaking ? "speaker.wave.2.fill" : "speaker.wave.2")
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(daemon: daemon)
        }
    }
}
