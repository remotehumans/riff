// ABOUTME: ObservableObject that communicates with the Riff daemon over a Unix socket.
// ABOUTME: Polls status every 2 seconds and exposes methods to control narration.

import Foundation
import Combine
import AppKit
import CoreAudio

class DaemonConnection: ObservableObject {
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
    @Published var systemInputDevices: [SystemAudioDevice] = []
    @Published var currentInputDeviceUID: String = ""

    private let socketPath = "/tmp/riff.sock"
    private var pollTimer: Timer?
    private let configPath = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".config/riff/config.json")

    init() {
        loadConfig()
        fetchVoices()
        fetchDevices()
        refreshSystemInputDevices()
        startPolling()
    }

    deinit {
        pollTimer?.invalidate()
    }

    // MARK: - Polling

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.fetchStatus()
        }
        fetchStatus()
    }

    private func fetchStatus() {
        let request: [String: Any] = ["type": "status"]
        sendRequest(request) { [weak self] response in
            guard let self, let response else {
                DispatchQueue.main.async { self?.connected = false }
                return
            }
            DispatchQueue.main.async {
                self.connected = true
                self.speaking = response["speaking"] as? Bool ?? false
                self.queueDepth = response["queue_depth"] as? Int ?? 0
                self.currentSession = response["current_session"] as? String
                self.enabled = response["enabled"] as? Bool ?? true
                self.speed = response["speed"] as? Double ?? 1.0
                self.loadConfig()
            }
        }
    }

    private func fetchVoices() {
        let request: [String: Any] = ["type": "list_voices"]
        sendRequest(request) { [weak self] response in
            guard let self, let response,
                  let voiceList = response["voices"] as? [String] else { return }
            DispatchQueue.main.async {
                self.voices = voiceList
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
        let request: [String: Any] = ["type": "list_devices"]
        sendRequest(request) { [weak self] response in
            guard let self, let response,
                  let devices = response["output_devices"] as? [[String: Any]] else { return }
            DispatchQueue.main.async {
                self.outputDevices = devices.compactMap { dict in
                    guard let index = dict["index"] as? Int,
                          let name = dict["name"] as? String,
                          let isDefault = dict["is_default"] as? Bool else { return nil }
                    return AudioDeviceInfo(index: index, name: name, isDefault: isDefault)
                }
                self.currentOutputDevice = response["current"] as? Int
            }
        }
    }

    func setOutputDevice(_ index: Int?) {
        currentOutputDevice = index
        var request: [String: Any] = ["type": "set_output_device"]
        if let index { request["device"] = index }
        fire(request)
    }

    func refreshSystemInputDevices() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            var devices: [SystemAudioDevice] = []
            var currentDefault: AudioDeviceID = 0

            // Get default input device
            var defaultAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDefaultInputDevice,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var defaultSize = UInt32(MemoryLayout<AudioDeviceID>.size)
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &defaultAddr, 0, nil, &defaultSize, &currentDefault
            )

            // Get all audio devices
            var devicesAddr = AudioObjectPropertyAddress(
                mSelector: kAudioHardwarePropertyDevices,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var propSize: UInt32 = 0
            AudioObjectGetPropertyDataSize(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddr, 0, nil, &propSize
            )

            let deviceCount = Int(propSize) / MemoryLayout<AudioDeviceID>.size
            var deviceIDs = [AudioDeviceID](repeating: 0, count: deviceCount)
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &devicesAddr, 0, nil, &propSize, &deviceIDs
            )

            for deviceID in deviceIDs {
                // Check if device has input channels
                var inputAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyStreamConfiguration,
                    mScope: kAudioDevicePropertyScopeInput,
                    mElement: kAudioObjectPropertyElementMain
                )
                var bufSize: UInt32 = 0
                guard AudioObjectGetPropertyDataSize(deviceID, &inputAddr, 0, nil, &bufSize) == noErr,
                      bufSize > 0 else { continue }

                let bufferList = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(bufSize))
                defer { bufferList.deallocate() }
                guard AudioObjectGetPropertyData(deviceID, &inputAddr, 0, nil, &bufSize, bufferList) == noErr else { continue }

                let channelCount = (0..<Int(bufferList.pointee.mNumberBuffers)).reduce(0) { total, i in
                    let buf = UnsafeRawPointer(bufferList).advanced(by: MemoryLayout<UInt32>.size + i * MemoryLayout<AudioBuffer>.size)
                        .assumingMemoryBound(to: AudioBuffer.self).pointee
                    return total + Int(buf.mNumberChannels)
                }
                guard channelCount > 0 else { continue }

                // Get device name
                var nameAddr = AudioObjectPropertyAddress(
                    mSelector: kAudioDevicePropertyDeviceNameCFString,
                    mScope: kAudioObjectPropertyScopeGlobal,
                    mElement: kAudioObjectPropertyElementMain
                )
                var nameRef: CFString = "" as CFString
                var nameSize = UInt32(MemoryLayout<CFString>.size)
                AudioObjectGetPropertyData(deviceID, &nameAddr, 0, nil, &nameSize, &nameRef)
                let name = nameRef as String

                devices.append(SystemAudioDevice(
                    id: deviceID,
                    name: name,
                    isDefault: deviceID == currentDefault
                ))
            }

            let defaultUID = currentDefault
            DispatchQueue.main.async {
                self?.systemInputDevices = devices
                self?.currentInputDeviceUID = String(defaultUID)
            }
        }
    }

    func setSystemInputDevice(_ deviceID: AudioDeviceID) {
        var id = deviceID
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        AudioObjectSetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        currentInputDeviceUID = String(deviceID)
        refreshSystemInputDevices()
    }

    // MARK: - Config File Access

    private func loadConfig() {
        guard let config = loadConfigDict() else { return }
        defaultVoice = config["default_voice"] as? String ?? "am_adam"
        announcerVoice = config["announcer_voice"] as? String ?? "af_heart"

        let names = config["session_names"] as? [String: String] ?? [:]
        let voiceMap = config["voice_map"] as? [String: String] ?? [:]
        sessions = names.map { key, name in
            SessionInfo(key: key, displayName: name, voice: voiceMap[key] ?? defaultVoice)
        }.sorted(by: { $0.displayName < $1.displayName })
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
        DispatchQueue.global(qos: .utility).async { [socketPath] in
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

// MARK: - Audio Device Models

struct AudioDeviceInfo: Identifiable {
    let index: Int
    let name: String
    let isDefault: Bool

    var id: Int { index }
}

struct SystemAudioDevice: Identifiable {
    let id: AudioDeviceID
    let name: String
    let isDefault: Bool
}
