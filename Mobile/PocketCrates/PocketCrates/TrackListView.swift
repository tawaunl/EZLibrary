import SwiftUI
import EZLibrarySnapshotKit

// MARK: - Sort

enum TrackSortOption: String, CaseIterable, Identifiable {
    case defaultOrder = "Default"
    case title        = "Title"
    case artist       = "Artist"
    case album        = "Album"
    case bpm          = "BPM"
    case key          = "Key"
    case dateAdded    = "Date Added"

    var id: String { rawValue }

    var systemImage: String {
        switch self {
        case .defaultOrder: return "list.number"
        case .title:        return "textformat.abc"
        case .artist:       return "person"
        case .album:        return "square.stack"
        case .bpm:          return "metronome"
        case .key:          return "music.quarternote.3"
        case .dateAdded:    return "calendar"
        }
    }
}

// MARK: - View

struct TrackListView: View {
    let library: SnapshotLibrary
    let scope: LibraryScope

    @State private var query = ""
    @State private var sortOption: TrackSortOption = .defaultOrder

    private var tracks: [SnapshotTrack] {
        let base: [SnapshotTrack]
        switch scope {
        case .allTracks:
            base = library.search(query)
        case .notInCrates:
            let unfiled = library.tracksNotInAnyCrate
            guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { base = unfiled; break }
            let matching = Set(library.search(query).map(\.storedPath))
            base = unfiled.filter { matching.contains($0.storedPath) }
        case let .crate(node):
            base = library.search(query, in: node)
        }
        return sorted(base)
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
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Picker("Sort by", selection: $sortOption) {
                        ForEach(TrackSortOption.allCases) { option in
                            Label(option.rawValue, systemImage: option.systemImage)
                                .tag(option)
                        }
                    }
                } label: {
                    Label("Sort", systemImage: sortOption == .defaultOrder
                          ? "arrow.up.arrow.down"
                          : "arrow.up.arrow.down.circle.fill")
                }
            }
        }
        .overlay {
            if tracks.isEmpty {
                ContentUnavailableView.search(text: query)
            }
        }
    }

    private func sorted(_ list: [SnapshotTrack]) -> [SnapshotTrack] {
        switch sortOption {
        case .defaultOrder: return list
        case .title:        return list.sorted { $0.displayTitle.localizedCompare($1.displayTitle) == .orderedAscending }
        case .artist:       return list.sorted { $0.artist.localizedCompare($1.artist) == .orderedAscending }
        case .album:        return list.sorted { $0.album.localizedCompare($1.album) == .orderedAscending }
        case .bpm:          return list.sorted { ($0.bpm ?? 0) < ($1.bpm ?? 0) }
        case .key:          return list.sorted { ($0.camelotKey ?? "") < ($1.camelotKey ?? "") }
        case .dateAdded:    return list.sorted { ($0.dateAdded ?? .distantPast) > ($1.dateAdded ?? .distantPast) }
        }
    }
}

// MARK: - Track Row

private struct TrackRow: View {
    let track: SnapshotTrack

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
                Text(track.displayTitle)
                    .font(.body)
                    .lineLimit(1)

                HStack(spacing: 4) {
                    if !track.artist.isEmpty {
                        Text(track.artist)
                            .lineLimit(1)
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

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 3) {
                if let key = track.camelotKey {
                    Text(key)
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tint)
                }
                if let bpm = track.bpm {
                    let bpmStr = bpm == bpm.rounded()
                        ? String(Int(bpm))
                        : String(format: "%.1f", bpm)
                    Text(bpmStr)
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - SnapshotTrack helpers

extension SnapshotTrack {
    var displayTitle: String {
        title.isEmpty ? (storedPath as NSString).lastPathComponent : title
    }

    var camelotKey: String? {
        guard let k = key, !k.isEmpty else { return nil }
        return KeyFormatter.camelot(from: k)
    }
}
