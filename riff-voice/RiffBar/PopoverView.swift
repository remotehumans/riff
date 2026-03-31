// ABOUTME: Main menu bar popover for Riff voice narrator controls.
// ABOUTME: Shows daemon status, speed/enable controls, queue info, session list, and action buttons.

import SwiftUI

struct PopoverView: View {
    @ObservedObject var daemon: DaemonConnection

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header: connection status + speaking state
            headerSection

            Divider()
                .padding(.vertical, 8)

            // Controls: enable toggle, speed slider, interrupt/read full
            controlsSection

            // Queue depth indicator
            if daemon.queueDepth > 0 {
                queueIndicator
                    .padding(.top, 6)
            }

            Divider()
                .padding(.vertical, 8)

            // Sessions list
            sessionsSection

            Divider()
                .padding(.vertical, 8)

            // Footer: settings + quit
            footerSection
        }
        .padding(16)
        .frame(width: 420)
        .preferredColorScheme(.dark)
    }

    // MARK: - Header

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Circle()
                    .fill(daemon.connected ? Color.green : Color.red)
                    .frame(width: 8, height: 8)

                Text(daemon.connected ? "Riff" : "Daemon Offline")
                    .font(.system(.headline, weight: .semibold))

                Spacer()
            }

            // Current activity line
            if daemon.speaking, let session = daemon.currentSession {
                HStack(spacing: 6) {
                    WaveformView()
                        .frame(width: 20, height: 14)

                    let name = daemon.sessionName(for: session)
                    Text("Speaking: \(name)")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            } else {
                Text("Idle")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            }
        }
    }

    // MARK: - Controls

    private var controlsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Enable/disable toggle
            Toggle("Enabled", isOn: Binding(
                get: { daemon.enabled },
                set: { daemon.setEnabled($0) }
            ))
            .toggleStyle(.switch)

            // Speed slider
            HStack(spacing: 8) {
                Text("Speed")
                    .font(.subheadline)
                    .frame(width: 42, alignment: .leading)

                Slider(
                    value: Binding(
                        get: { daemon.speed },
                        set: { daemon.setSpeed($0) }
                    ),
                    in: 0.5...3.0,
                    step: 0.1
                )

                Text(String(format: "%.1fx", daemon.speed))
                    .font(.system(.subheadline, design: .monospaced))
                    .foregroundColor(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }

            // Action buttons row
            HStack(spacing: 8) {
                Button {
                    daemon.interrupt()
                } label: {
                    Label("Interrupt", systemImage: "stop.fill")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
                .tint(.red)
                .disabled(!daemon.speaking)

                Button {
                    daemon.readFull()
                } label: {
                    Label("Hear Full Response", systemImage: "text.bubble")
                        .font(.subheadline)
                }
                .buttonStyle(.bordered)
            }
        }
    }

    // MARK: - Queue Indicator

    private var queueIndicator: some View {
        HStack(spacing: 6) {
            Image(systemName: "tray.full")
                .font(.caption)
                .foregroundColor(.orange)
            Text("\(daemon.queueDepth) in queue")
                .font(.caption)
                .foregroundColor(.orange)
        }
    }

    // MARK: - Sessions

    private var sessionsSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Sessions")
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)

            if daemon.sessions.isEmpty {
                Text("No active sessions")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(daemon.sessions, id: \.key) { session in
                            SessionRow(
                                sessionKey: session.key,
                                displayName: session.displayName,
                                voiceName: session.voice,
                                availableVoices: daemon.voices,
                                onVoiceChanged: { newVoice in
                                    daemon.setVoice(session: session.key, voice: newVoice)
                                },
                                onNameChanged: { newName in
                                    daemon.setName(session: session.key, name: newName)
                                }
                            )
                            if session.key != daemon.sessions.last?.key {
                                Divider()
                            }
                        }
                    }
                }
                .frame(maxHeight: 180)
            }
        }
    }

    // MARK: - Footer

    private var footerSection: some View {
        HStack {
            Button("Settings...") {
                daemon.openSettings()
            }
            .buttonStyle(.plain)
            .foregroundColor(.accentColor)

            Spacer()

            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.plain)
            .foregroundColor(.secondary)
        }
        .font(.subheadline)
    }
}

// MARK: - Waveform Animation

struct WaveformView: View {
    @State private var animating = false

    private let barCount = 4
    private let barSpacing: CGFloat = 2
    private let barWidth: CGFloat = 2.5

    var body: some View {
        HStack(spacing: barSpacing) {
            ForEach(0..<barCount, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: barWidth)
                    .scaleEffect(y: animating ? CGFloat.random(in: 0.3...1.0) : 0.4, anchor: .bottom)
                    .animation(
                        .easeInOut(duration: 0.4)
                            .repeatForever(autoreverses: true)
                            .delay(Double(index) * 0.1),
                        value: animating
                    )
            }
        }
        .onAppear { animating = true }
        .onDisappear { animating = false }
    }
}

// MARK: - Session Data Model

struct SessionInfo: Identifiable {
    let key: String
    let displayName: String
    let voice: String

    var id: String { key }
}
