// ABOUTME: Reusable row view for displaying a Riff voice session in a list.
// ABOUTME: Shows session name (editable inline), voice picker dropdown, and session key.

import SwiftUI

struct SessionRow: View {
    let sessionKey: String
    let displayName: String
    let voiceName: String
    let availableVoices: [String]
    var onVoiceChanged: (String) -> Void
    var onNameChanged: (String) -> Void

    @State private var isEditingName = false
    @State private var editedName: String = ""

    var body: some View {
        HStack(spacing: 10) {
            // Session name - click pencil to edit inline
            if isEditingName {
                TextField("Session name", text: $editedName, onCommit: {
                    let trimmed = editedName.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty {
                        onNameChanged(trimmed)
                    }
                    isEditingName = false
                })
                .textFieldStyle(.plain)
                .font(.system(.body, weight: .semibold))
                .frame(maxWidth: 120)
            } else {
                Text(displayName)
                    .font(.system(.body, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.tail)

                Button {
                    editedName = displayName
                    isEditingName = true
                } label: {
                    Image(systemName: "pencil")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }

            Spacer()

            // Voice picker chip
            Picker("", selection: Binding(
                get: { voiceName },
                set: { onVoiceChanged($0) }
            )) {
                ForEach(availableVoices, id: \.self) { voice in
                    Text(voice).tag(voice)
                }
            }
            .labelsHidden()
            .frame(maxWidth: 130)
        }

        // Session key in small grey text
        Text(sessionKey)
            .font(.system(.caption2, design: .monospaced))
            .foregroundColor(.secondary)
            .lineLimit(1)
            .truncationMode(.middle)
    }
}
