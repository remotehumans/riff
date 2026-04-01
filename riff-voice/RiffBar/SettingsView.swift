// ABOUTME: Settings window for Riff voice narrator with Voices, Sessions, and About tabs.
// ABOUTME: Manages voice engine config, session-voice mappings, and app metadata.

import SwiftUI

struct SettingsView: View {
    @ObservedObject var daemon: DaemonConnection

    var body: some View {
        TabView {
            VoicesTab(daemon: daemon)
                .tabItem {
                    Label("Voices", systemImage: "waveform")
                }

            SessionsTab(daemon: daemon)
                .tabItem {
                    Label("Sessions", systemImage: "list.bullet")
                }

            AboutTab()
                .tabItem {
                    Label("About", systemImage: "info.circle")
                }
        }
        .frame(width: 500, height: 400)
        .preferredColorScheme(.dark)
    }
}

// MARK: - Voices Tab

struct VoicesTab: View {
    @ObservedObject var daemon: DaemonConnection

    var body: some View {
        Form {
            // Active voice engine card
            GroupBox {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Kokoro 82M")
                        .font(.system(.title3, weight: .semibold))

                    HStack(spacing: 6) {
                        Badge(text: "MLX", color: .blue)
                        Badge(text: "Apple Silicon", color: .purple)
                        Badge(text: "Local", color: .green)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(4)
            } label: {
                Label("Voice Engine", systemImage: "cpu")
                    .font(.headline)
            }

            // Default voice picker
            GroupBox {
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Picker("Default Voice", selection: Binding(
                            get: { daemon.defaultVoice },
                            set: { daemon.setDefaultVoice($0) }
                        )) {
                            ForEach(daemon.voices, id: \.self) { voice in
                                Text(voice).tag(voice)
                            }
                        }
                        .frame(maxWidth: 200)

                        Button {
                            daemon.previewVoice(daemon.defaultVoice)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Preview this voice")
                    }

                    HStack {
                        Picker("Announcer Voice", selection: Binding(
                            get: { daemon.announcerVoice },
                            set: { daemon.setAnnouncerVoice($0) }
                        )) {
                            ForEach(daemon.voices, id: \.self) { voice in
                                Text(voice).tag(voice)
                            }
                        }
                        .frame(maxWidth: 200)

                        Button {
                            daemon.previewVoice(daemon.announcerVoice)
                        } label: {
                            Image(systemName: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Preview this voice")
                    }
                }
            } label: {
                Label("Voice Selection", systemImage: "person.wave.2")
                    .font(.headline)
            }
        }
        .formStyle(.grouped)
        .padding()
    }
}

// MARK: - Sessions Tab

struct SessionsTab: View {
    @ObservedObject var daemon: DaemonConnection

    var body: some View {
        VStack(spacing: 0) {
            if daemon.sessions.isEmpty {
                Spacer()
                VStack(spacing: 8) {
                    Image(systemName: "bubble.left.and.bubble.right")
                        .font(.largeTitle)
                        .foregroundColor(.secondary)
                    Text("No sessions yet")
                        .font(.headline)
                        .foregroundColor(.secondary)
                    Text("Sessions appear when AI agents send messages to Riff.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .padding()
                Spacer()
            } else {
                // Column headers
                HStack(spacing: 0) {
                    Text("Session")
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("Voice")
                        .frame(width: 140, alignment: .leading)
                    Text("Key")
                        .frame(width: 120, alignment: .leading)
                }
                .font(.system(.caption, weight: .semibold))
                .foregroundColor(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(Color(nsColor: .controlBackgroundColor).opacity(0.5))

                Divider()

                // Session rows
                List {
                    ForEach(daemon.sessions) { session in
                        HStack(spacing: 0) {
                            Text(session.displayName)
                                .font(.system(.body, weight: .medium))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)

                            Picker("", selection: Binding(
                                get: { session.voice },
                                set: { daemon.setVoice(session: session.key, voice: $0) }
                            )) {
                                ForEach(daemon.voices, id: \.self) { voice in
                                    Text(voice).tag(voice)
                                }
                            }
                            .labelsHidden()
                            .frame(width: 140)

                            Text(session.key)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundColor(.secondary)
                                .lineLimit(1)
                                .truncationMode(.middle)
                                .frame(width: 120, alignment: .leading)
                        }
                    }
                }
            }

            Divider()

            // Footer actions
            HStack {
                Spacer()
                Button("Clear All Sessions", role: .destructive) {
                    daemon.clearAllSessions()
                }
                .disabled(daemon.sessions.isEmpty)
                .padding(12)
            }
        }
    }
}

// MARK: - About Tab

struct AboutTab: View {
    var body: some View {
        VStack(spacing: 16) {
            Spacer()

            Image(systemName: "speaker.wave.2.fill")
                .font(.system(size: 48))
                .foregroundColor(.accentColor)

            Text("Riff")
                .font(.system(.largeTitle, weight: .bold))

            Text("Version 0.1.0")
                .font(.subheadline)
                .foregroundColor(.secondary)

            VStack(spacing: 4) {
                Text("Voice narrator for AI coding agents")
                    .font(.body)
                Text("Built with MLX-Audio Kokoro TTS")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }

            Link("Riff on GitHub",
                 destination: URL(string: "https://github.com/remotehumans/riff")!)
                .font(.caption)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .padding()
    }
}

// MARK: - Badge Component

struct Badge: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(.system(.caption2, weight: .semibold))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .clipShape(Capsule())
    }
}
