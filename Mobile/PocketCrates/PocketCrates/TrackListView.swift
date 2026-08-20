import SwiftUI
import EZLibrarySnapshotKit

struct TrackListView: View {
    let library: SnapshotLibrary
    let scope: LibraryScope

    @State private var query = ""

    private var tracks: [SnapshotTrack] {
        switch scope {
        case .allTracks:
            return library.search(query)
        case .notInCrates:
            let unfiled = library.tracksNotInAnyCrate
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return unfiled }
            let matching = Set(library.search(query).map(\.storedPath))
            return unfiled.filter { matching.contains($0.storedPath) }
        case let .crate(node):
            return library.search(query, in: node)
        }
    }

    var body: some View {
        List(tracks, id: \.storedPath) { track in
            NavigationLink(value: track) {
                TrackRow(track: track)
            }
        }
        .listStyle(.plain)
        .searchable(text: $query, prompt: "Title, artist, album, genre")
        .autocorrectionDisabled()
        .textInputAutocapitalization(.never)
        .navigationTitle(scope.title)
        .navigationBarTitleDisplayMode(.inline)
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }
}

private struct TrackRow: View {
    let track: SnapshotTrack

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(track.title.isEmpty ? (track.storedPath as NSString).lastPathComponent : track.title)
                .font(.body)
                .lineLimit(1)

            HStack(spacing: 6) {
                if !track.artist.isEmpty {
                    Text(track.artist).lineLimit(1)
                }
                if let detail = track.bpmAndKey {
                    Text("·")
                    Text(detail).monospacedDigit()
                }
                if track.isMissing {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityLabel("File missing on the Mac")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }
}

extension SnapshotTrack {
    /// "124 · 8A", omitting whichever half is unknown.
    var bpmAndKey: String? {
        let parts = [
            bpm.map { $0 == $0.rounded() ? String(Int($0)) : String(format: "%.1f", $0) },
            key
        ].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
