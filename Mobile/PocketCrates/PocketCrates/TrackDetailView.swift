import SwiftUI
import EZLibrarySnapshotKit

struct TrackDetailView: View {
    let track: SnapshotTrack

    var body: some View {
        List {
            Section {
                ForEach(TrackField.allCases, id: \.self) { field in
                    if let value = track.value(for: field) {
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

            Section {
                Text("This is a read-only copy. Editing from your phone is coming in a later version.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .navigationTitle(track.title.isEmpty ? "Track" : track.title)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func formatted(_ duration: TimeInterval) -> String {
        let total = Int(duration.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}
