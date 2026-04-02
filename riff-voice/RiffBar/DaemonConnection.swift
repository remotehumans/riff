// ABOUTME: ObservableObject that communicates with the Riff daemon over a Unix socket.
// ABOUTME: Polls status every 2 seconds and exposes methods to control narration.

import Foundation
import Combine
import AppKit

final class DaemonConnection: ObservableObject {
    @Published var speaking: Bool = false
    @Published var queueDepth: Int = 0
    @Published var currentSession: String?
    @Published var enabled: Bool = true
    @Published var speed: Double = 1.0
    @Published var voices: [String] = []
    @Published var connected: Bool = false
    @Published var defaultVoice: String = "am_adam"
    @Published var announcerVoice: String = "af_heart"
    @Published var sessions: [SessionInfo] = []
    @Published var outputDevices: [AudioDeviceInfo] = []
    @Published var currentOutputDevice: Int? = nil  // nil = system default
    @Published var inputDevices: [AudioDeviceInfo] = []
    @Published var currentInputDevice: Int? = nil  // tracks which input is default

    private let socketPath = "/tmp/riff.sock"
    private var pollTimer: Timer?
    private let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/riff/config.json")
    private var pollInterval: TimeInterval = 5.0
    private let requestQueue = DispatchQueue(label: "com.riffbar.daemon-connection", qos: .utility)
    private var statusRequestInFlight = false
    private var voicesRequestInFlight = false
    private var devicesRequestInFlight = false

    init() {
        loadConfig()
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    /// Call when popover opens to fetch fresh data and poll faster
    func popoverOpened() {
        fetchVoices()
        fetchDevices()
        fetchStatus()
        setPollInterval(2.0)
    }

    /// Call when popover closes to reduce polling frequency
    func popoverClosed() {
        setPollInterval(5.0)
    }

    private func setPollInterval(_ interval: TimeInterval) {
        guard interval != pollInterval else { return }
        pollInterval = interval
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            self?.fetchStatus()
        }
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: pollInterval, repeats: true) { [weak self] _ in
            self?.fetchStatus()
        }
        fetchStatus()
    }

    private var lastConfigModTime: Date?

    private func fetchStatus() {
        guard !statusRequestInFlight else { return }
        statusRequestInFlight = true

        let request: [String: Any] = ["type": "status"]
        sendRequest(request) { [weak self] response in
            guard let self, let response else {
                DispatchQueue.main.async {
                    self?.statusRequestInFlight = false
                    self?.connected = false
                }
                return
            }

            let attrs = try? FileManager.default.attributesOfItem(atPath: self.configPath.path)
            let modTime = attrs?[.modificationDate] as? Date
            let config = modTime != self.lastConfigModTime ? self.loadConfigDict() : nil

            DispatchQueue.main.async {
                self.statusRequestInFlight = false
                self.connected = true
                self.updatePublishedValue(&self.speaking, with: response["speaking"] as? Bool ?? false)
                self.updatePublishedValue(&self.queueDepth, with: response["queue_depth"] as? Int ?? 0)
                self.updatePublishedValue(&self.currentSession, with: response["current_session"] as? String)
                self.updatePublishedValue(&self.enabled, with: response["enabled"] as? Bool ?? true)
                self.updatePublishedValue(&self.speed, with: response["speed"] as? Double ?? 1.0)

                if let config {
                    self.lastConfigModTime = modTime
                    self.applyConfig(config)
                }
            }
        }
    }

    private func fetchVoices() {
        guard !voicesRequestInFlight else { return }
        voicesRequestInFlight = true

        let request: [String: Any] = ["type": "list_voices"]
        sendRequest(request) { [weak self] response in
            guard let self else { return }
            guard let response,
                  let voiceList = response["voices"] as? [String] else {
                DispatchQueue.main.async {
                    self.voicesRequestInFlight = false
                }
                return
            }

            DispatchQueue.main.async {
                self.voicesRequestInFlight = false
                self.updatePublishedValue(&self.voices, with: voiceList)
            }
        }
    }

    // MARK: - Control Methods

    func interrupt() {
        fire(["type": "interrupt"])
    }

    func skip() {
        fire(["type": "skip"])
    }

    func setSpeed(_ value: Double) {
        speed = value
        fire(["type": "set_speed", "speed": value])
    }

    func setEnabled(_ value: Bool) {
        enabled = value
        fire(["type": "set_enabled", "enabled": value])
    }

    func setVoice(session: String, voice: String) {
        fire(["type": "set_voice", "session": session, "voice": voice])
    }

    func setName(session: String, name: String) {
        fire(["type": "set_name", "session": session, "name": name])
    }

    func readFull() {
        fire(["type": "read_full"])
    }

    func sessionName(for key: String) -> String {
        sessions.first(where: { $0.key == key })?.displayName ?? key
    }

    func openSettings() {
        if #available(macOS 14.0, *) {
            NSApp.activate()
        } else {
            NSApp.activate(ignoringOtherApps: true)
        }
        // Try both selectors - name changed between macOS versions
        if NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil) {
            return
        }
        // Fallback for macOS 13
        NSApp.sendAction(Selector(("showPreferencesWindow:")), to: nil, from: nil)
    }

    func clearAllSessions() {
        // Clear sessions from config file
        if var config = loadConfigDict() {
            config["session_names"] = [String: String]() as [String: String]
            config["voice_map"] = [String: String]() as [String: String]
            saveConfigDict(config)
            loadConfig()
        }
    }

    func previewVoice(_ voice: String) {
        fire(["type": "speak", "text": "Hello, this is the \(voice) voice.", "session": "preview", "voice": voice])
    }

    func setDefaultVoice(_ voice: String) {
        defaultVoice = voice
        if var config = loadConfigDict() {
            config["default_voice"] = voice
            saveConfigDict(config)
        }
    }

    func setAnnouncerVoice(_ voice: String) {
        announcerVoice = voice
        if var config = loadConfigDict() {
            config["announcer_voice"] = voice
            saveConfigDict(config)
        }
    }

    // MARK: - Audio Devices

    func fetchDevices() {
        guard !devicesRequestInFlight else { return }
        devicesRequestInFlight = true

        let request: [String: Any] = ["type": "list_devices"]
        sendRequest(request) { [weak self] response in
            guard let self else { return }
            guard let response else {
                DispatchQueue.main.async {
                    self.devicesRequestInFlight = false
                }
                return
            }

            let outputDevices = (response["output_devices"] as? [[String: Any]])?.compactMap(Self.parseAudioDevice)
            let inputDevices = (response["input_devices"] as? [[String: Any]])?.compactMap(Self.parseAudioDevice)
            let currentInputDevice = inputDevices?.first(where: { $0.isDefault })?.index
            let currentOutputDevice = response["current"] as? Int

            DispatchQueue.main.async {
                self.devicesRequestInFlight = false
                if let outputDevices {
                    self.updatePublishedValue(&self.outputDevices, with: outputDevices)
                }
                if let inputDevices {
                    self.updatePublishedValue(&self.inputDevices, with: inputDevices)
                    self.updatePublishedValue(&self.currentInputDevice, with: currentInputDevice)
                }
                self.updatePublishedValue(&self.currentOutputDevice, with: currentOutputDevice)
            }
        }
    }

    func setOutputDevice(_ index: Int?) {
        currentOutputDevice = index
        var request: [String: Any] = ["type": "set_output_device"]
        if let index { request["device"] = index }
        fire(request)
    }

    func setSystemInputDevice(_ name: String) {
        // Use SwitchAudioSource if available, otherwise use osascript with CoreAudio
        DispatchQueue.global(qos: .utility).async { [weak self] in
            let task = Process()
            task.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            // Use CoreAudio via osascript to set the default input device by name
            let script = """
            use framework "CoreAudio"
            use scripting additions

            set targetName to "\(name)"

            -- Get all audio device IDs
            set deviceCount to (do shell script "system_profiler SPAudioDataType 2>/dev/null | grep -c 'Input Source' || echo 0") as integer

            -- Use SwitchAudioSource if available
            try
                do shell script "/opt/homebrew/bin/SwitchAudioSource -t input -s " & quoted form of targetName
            on error
                try
                    do shell script "/usr/local/bin/SwitchAudioSource -t input -s " & quoted form of targetName
                end try
            end try
            """
            task.arguments = ["-e", script]
            task.standardOutput = Pipe()
            task.standardError = Pipe()
            try? task.run()
            task.waitUntilExit()

            // Refresh device list to pick up the change
            DispatchQueue.main.async {
                self?.fetchDevices()
            }
        }
    }

    // MARK: - Config File Access

    private func loadConfig() {
        guard let config = loadConfigDict() else { return }
        applyConfig(config)
    }

    private func loadConfigDict() -> [String: Any]? {
        guard let data = try? Data(contentsOf: configPath),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return dict
    }

    private func saveConfigDict(_ dict: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: dict, options: [.prettyPrinted, .sortedKeys]) else { return }
        try? data.write(to: configPath)
    }

    // MARK: - Socket Communication

    /// Fire-and-forget: send a request without caring about the response.
    private func fire(_ request: [String: Any]) {
        sendRequest(request) { _ in }
    }

    /// Send a JSON request to the daemon socket and call the completion handler with the parsed response.
    /// Each call opens a new connection, sends, reads, and closes (simple and stateless).
    private func sendRequest(_ request: [String: Any], completion: @escaping ([String: Any]?) -> Void) {
        requestQueue.async { [socketPath] in
            autoreleasepool {
            guard FileManager.default.fileExists(atPath: socketPath) else {
                completion(nil)
                return
            }

            // Create Unix domain socket
            let fd = socket(AF_UNIX, SOCK_STREAM, 0)
            guard fd >= 0 else {
                completion(nil)
                return
            }

            // Connect via Unix socket
            var addr = sockaddr_un()
            addr.sun_family = sa_family_t(AF_UNIX)
            // Copy path bytes safely without overlapping access
            let pathBytes = Array(socketPath.utf8CString)
            let maxLen = MemoryLayout.size(ofValue: addr.sun_path)
            withUnsafeMutableBytes(of: &addr.sun_path) { rawBuf in
                let dest = rawBuf.bindMemory(to: CChar.self)
                for i in 0..<min(pathBytes.count, maxLen) {
                    dest[i] = pathBytes[i]
                }
            }

            let addrLen = socklen_t(MemoryLayout<sockaddr_un>.size)
            let connectResult = withUnsafePointer(to: &addr) { ptr in
                ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sockaddrPtr in
                    Darwin.connect(fd, sockaddrPtr, addrLen)
                }
            }

            guard connectResult == 0 else {
                close(fd)
                completion(nil)
                return
            }

            // Serialize request to JSON + newline
            guard let jsonData = try? JSONSerialization.data(withJSONObject: request),
                  var message = String(data: jsonData, encoding: .utf8) else {
                close(fd)
                completion(nil)
                return
            }
            message += "\n"

            // Send
            let sent = message.withCString { ptr in
                Darwin.send(fd, ptr, message.utf8.count, 0)
            }
            guard sent > 0 else {
                close(fd)
                completion(nil)
                return
            }

            // Read response (up to 64KB)
            var buffer = [UInt8](repeating: 0, count: 65536)
            var accumulated = Data()
            let readTimeout = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, [readTimeout], socklen_t(MemoryLayout<timeval>.size))

            while true {
                let bytesRead = Darwin.recv(fd, &buffer, buffer.count, 0)
                if bytesRead <= 0 { break }
                accumulated.append(contentsOf: buffer[0..<bytesRead])
                // Check for newline delimiter
                if accumulated.contains(UInt8(ascii: "\n")) { break }
            }

            close(fd)

            // Parse response
            guard !accumulated.isEmpty,
                  let parsed = try? JSONSerialization.jsonObject(with: accumulated) as? [String: Any] else {
                completion(nil)
                return
            }
            completion(parsed)
            }
        }
    }

    private func applyConfig(_ config: [String: Any]) {
        let defaultVoice = config["default_voice"] as? String ?? "am_adam"
        let announcerVoice = config["announcer_voice"] as? String ?? "af_heart"
        let names = config["session_names"] as? [String: String] ?? [:]
        let voiceMap = config["voice_map"] as? [String: String] ?? [:]
        let sessions = names.map { key, name in
            SessionInfo(key: key, displayName: name, voice: voiceMap[key] ?? defaultVoice)
        }.sorted(by: { $0.displayName < $1.displayName })

        updatePublishedValue(&self.defaultVoice, with: defaultVoice)
        updatePublishedValue(&self.announcerVoice, with: announcerVoice)
        updatePublishedValue(&self.sessions, with: sessions)
    }

    private func updatePublishedValue<Value: Equatable>(_ currentValue: inout Value, with newValue: Value) {
        guard currentValue != newValue else { return }
        currentValue = newValue
    }

    private static func parseAudioDevice(from dict: [String: Any]) -> AudioDeviceInfo? {
        guard let index = dict["index"] as? Int,
              let name = dict["name"] as? String,
              let isDefault = dict["is_default"] as? Bool else { return nil }
        return AudioDeviceInfo(index: index, name: name, isDefault: isDefault)
    }
}

// MARK: - Audio Device Models

struct AudioDeviceInfo: Identifiable, Equatable {
    let index: Int
    let name: String
    let isDefault: Bool

    var id: Int { index }
}
