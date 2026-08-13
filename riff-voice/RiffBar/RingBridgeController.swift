// ABOUTME: Controls the optional Riff Bridge LaunchAgent from the RiffBar menu.
// ABOUTME: Detects installation, running state, and JX-11 connection status.

import Foundation
import Combine

final class RingBridgeController: ObservableObject {
    @Published private(set) var isAvailable = false
    @Published private(set) var isEnabled = false
    @Published private(set) var isConnected = false
    @Published private(set) var isChanging = false
    @Published private(set) var errorMessage: String?

    private let label = "co.remotehumans.riff-bridge"
    private let plistURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/LaunchAgents/co.remotehumans.riff-bridge.plist")
    private let logURL = URL(fileURLWithPath: "/tmp/riff-bridge.log")
    private let queue = DispatchQueue(label: "com.riffbar.ring-bridge", qos: .utility)
    private var pollTimer: Timer?
    private var refreshInFlight = false

    var statusText: String {
        if isChanging { return "Updating..." }
        if let errorMessage { return errorMessage }
        if !isEnabled { return "Off" }
        return isConnected ? "JX-11 connected" : "Waiting for JX-11"
    }

    init() {
        refresh()
        setPollInterval(5.0)
    }

    deinit {
        pollTimer?.invalidate()
    }

    func popoverOpened() {
        refresh()
        setPollInterval(2.0)
    }

    func popoverClosed() {
        setPollInterval(5.0)
    }

    func setEnabled(_ enabled: Bool) {
        guard isAvailable, !isChanging else { return }
        isChanging = true
        errorMessage = nil

        queue.async { [weak self] in
            guard let self else { return }
            let result = enabled ? self.startBridge() : self.stopBridge()

            DispatchQueue.main.async {
                self.isChanging = false
                if !result.succeeded {
                    self.errorMessage = "Could not update ring"
                    NSLog("RiffBar ring control failed: %@", result.output)
                }
                self.refresh()
            }
        }
    }

    func refresh() {
        guard !refreshInFlight else { return }
        refreshInFlight = true

        queue.async { [weak self] in
            guard let self else { return }
            let available = FileManager.default.fileExists(atPath: self.plistURL.path)
            let running = available && self.isServiceRunning()
            let connected = running && self.logShowsConnectedRing()

            DispatchQueue.main.async {
                self.refreshInFlight = false
                self.isAvailable = available
                self.isEnabled = running
                self.isConnected = connected
                if running || !available {
                    self.errorMessage = nil
                }
            }
        }
    }

    private func setPollInterval(_ interval: TimeInterval) {
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.refresh()
        }
    }

    private func startBridge() -> CommandResult {
        let target = serviceTarget
        let enableResult = runLaunchctl(["enable", target])
        guard enableResult.succeeded else { return enableResult }

        if isServiceRunning() {
            return CommandResult(status: 0, output: "Already running")
        }

        let bootstrapResult = runLaunchctl([
            "bootstrap", serviceDomain, plistURL.path,
        ])
        if bootstrapResult.succeeded {
            return bootstrapResult
        }

        return runLaunchctl(["kickstart", "-k", target])
    }

    private func stopBridge() -> CommandResult {
        let disableResult = runLaunchctl(["disable", serviceTarget])
        guard disableResult.succeeded else { return disableResult }

        let bootoutResult = runLaunchctl([
            "bootout", serviceDomain, plistURL.path,
        ])

        // launchctl reports an error when an already-stopped service is booted
        // out. The requested end state is still satisfied.
        if bootoutResult.succeeded || !isServiceRunning() {
            return CommandResult(status: 0, output: bootoutResult.output)
        }
        return bootoutResult
    }

    private func isServiceRunning() -> Bool {
        let result = runLaunchctl(["print", serviceTarget])
        return result.succeeded && result.output.contains("state = running")
    }

    private func logShowsConnectedRing() -> Bool {
        guard let data = try? Data(contentsOf: logURL),
              let log = String(data: data.suffix(65_536), encoding: .utf8) else {
            return false
        }

        let currentRun = log.components(separatedBy: "JX-11 Ring -> FluidVoice Bridge").last ?? log
        let connected = currentRun.range(of: "Ring connected", options: .backwards)?.lowerBound
        let disconnected = currentRun.range(of: "Ring disconnected", options: .backwards)?.lowerBound

        guard let connected else { return false }
        guard let disconnected else { return true }
        return connected > disconnected
    }

    private var serviceDomain: String {
        "gui/\(getuid())"
    }

    private var serviceTarget: String {
        "\(serviceDomain)/\(label)"
    }

    private func runLaunchctl(_ arguments: [String]) -> CommandResult {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = output

        do {
            try process.run()
            process.waitUntilExit()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            return CommandResult(
                status: process.terminationStatus,
                output: String(data: data, encoding: .utf8) ?? ""
            )
        } catch {
            return CommandResult(status: -1, output: error.localizedDescription)
        }
    }
}

private struct CommandResult {
    let status: Int32
    let output: String

    var succeeded: Bool { status == 0 }
}
