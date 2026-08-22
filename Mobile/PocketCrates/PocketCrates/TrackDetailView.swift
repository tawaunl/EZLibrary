import SwiftUI
import EZLibrarySnapshotKit

// MARK: - Detail view

struct TrackDetailView: View {
    let track: SnapshotTrack

    @Environment(SnapshotStore.self) private var store
    @State private var isEditing = false

    var body: some View {
        List {
            Section {
                ForEach(TrackField.allCases, id: \.self) { field in
                    if let value = displayValue(for: field) {
                        LabeledContent(field.displayName, value: value)
                    }
                }
            }

            Section("Details") {
                if let duration = track.duration, duration > 0 {
                    LabeledContent("Length", value: formatted(duration))
                }
                if let bitrate = track.bitrate, !bitrate.isEmpty {
                    LabeledContent("Bitrate", value: bitrate)
                }
                if let plays = track.playCount {
                    LabeledContent("Plays", value: String(plays))
                }
                if let added = track.dateAdded {
                    LabeledContent("Added", value: added.formatted(date: .abbreviated, time: .omitted))
                }
            }

            Section("File") {
                Text(track.storedPath)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)

                if track.isMissing {
                    Label("Serato couldn't find this file", systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .font(.callout)
                }
            }
        }
        .navigationTitle(track.displayTitle)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Edit") { isEditing = true }
            }
        }
        .sheet(isPresented: $isEditing) {
            TrackEditView(track: track) { changes in
                for (field, newValue) in changes {
                    store.addIntent(.editTrackField(
                        storedPath: track.storedPath,
                        field: field,
                        oldValue: track.value(for: field),
                        newValue: newValue
                    ))
                }
            }
        }
    }

    private func displayValue(for field: TrackField) -> String? {
        if field == .key, let raw = track.key, !raw.isEmpty {
            return KeyFormatter.camelot(from: raw)
        }
        return track.value(for: field)
    }

    private func formatted(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

// MARK: - Edit sheet

private struct TrackEditView: View {
    let track: SnapshotTrack
    let onSave: ([TrackField: String]) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var values: [TrackField: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                ForEach(TrackField.allCases, id: \.self) { field in
                    LabeledContent(field.displayName) {
                        TextField(
                            field.displayName,
                            text: Binding(
                                get: { values[field, default: track.value(for: field) ?? ""] },
                                set: { values[field] = $0 }
                            )
                        )
                        .multilineTextAlignment(.trailing)
                        .autocorrectionDisabled(field == .key || field == .bpm)
                    }
                }

                Section {
                    Text("Changes are queued locally and will be applied to your Serato library the next time you sync with your Mac.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Edit Track")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let changed = values.filter { field, newValue in
                            !newValue.isEmpty && newValue != (track.value(for: field) ?? "")
                        }
                        if !changed.isEmpty { onSave(changed) }
                        dismiss()
                    }
                    .fontWeight(.semibold)
                }
            }
        }
    }
}
