import SwiftUI
import SeratoToolsCore

/// A sortable, searchable library-style table of tracks — shared by the
/// top-level Tracks section and crate detail views, so both look and
/// behave consistently.
struct TrackTableView: View {
    enum NumberingMode {
        case metadata
        case listOrder
    }

    let tracks: [Track]
    let numberingMode: NumberingMode

    @State private var sortOrder: [KeyPathComparator<Track>] = [KeyPathComparator(\.title)]
    @State private var searchText = ""

    init(tracks: [Track], numberingMode: NumberingMode = .metadata) {
        self.tracks = tracks
        self.numberingMode = numberingMode
    }

    var body: some View {
        VStack(spacing: 8) {
            TextField("Search title, artist, genre...", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 8)
                .padding(.top, 8)

            Table(filteredAndSorted, sortOrder: $sortOrder) {
                TableColumn("#", value: \.numberSortValue) { track in
                    Text(track.trackNumber.map(String.init) ?? "—")
                }
                TableColumn("Title", value: \.title)
                TableColumn("Artist", value: \.artist)
                TableColumn("Album", value: \.album)
                TableColumn("Genre", value: \.genre)
                TableColumn("Color", value: \.colorSortValue) { track in
                    HStack(spacing: 6) {
                        Circle()
                            .fill(track.swiftUIColor ?? .clear)
                            .overlay(Circle().stroke(.secondary.opacity(0.4), lineWidth: 1))
                            .frame(width: 10, height: 10)
                        Text(track.colorLabel)
                    }
                }
                TableColumn("Key", value: \.keySortValue) { track in
                    Text(track.key ?? "—")
                }
                TableColumn("BPM", value: \.bpmSortValue) { track in
                    Text(Self.formattedBPM(track.bpm))
                }
                TableColumn("Duration") { track in Text(Self.formattedDuration(track.duration)) }
            }
        }
    }

    private var filteredAndSorted: [Track] {
        let sourceTracks: [Track]
        switch numberingMode {
        case .metadata:
            sourceTracks = tracks
        case .listOrder:
            sourceTracks = tracks.enumerated().map { index, track in
                var track = track
                track.trackNumber = index + 1
                return track
            }
        }

        let base = searchText.isEmpty ? sourceTracks : sourceTracks.filter { track in
            track.title.localizedCaseInsensitiveContains(searchText)
                || track.artist.localizedCaseInsensitiveContains(searchText)
                || track.genre.localizedCaseInsensitiveContains(searchText)
                || track.album.localizedCaseInsensitiveContains(searchText)
        }
        return base.sorted(using: sortOrder)
    }

    private static func formattedBPM(_ bpm: Double?) -> String {
        guard let bpm else { return "—" }
        return String(format: "%.0f", bpm)
    }

    private static func formattedDuration(_ duration: TimeInterval?) -> String {
        guard let duration, duration > 0 else { return "—" }
        let minutes = Int(duration) / 60
        let seconds = Int(duration) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}

private extension Track {
    var numberSortValue: Int {
        trackNumber ?? Int.max
    }

    var keySortValue: String {
        key ?? ""
    }

    var bpmSortValue: Double {
        bpm ?? -1
    }

    var colorSortValue: UInt32 {
        colorCode ?? UInt32.max
    }

    var colorLabel: String {
        guard let colorCode else { return "—" }
        return String(format: "#%06X", colorCode & 0x00FF_FFFF)
    }

    var swiftUIColor: Color? {
        guard let colorCode else { return nil }
        let rgb = colorCode & 0x00FF_FFFF
        let red = Double((rgb >> 16) & 0xFF) / 255.0
        let green = Double((rgb >> 8) & 0xFF) / 255.0
        let blue = Double(rgb & 0xFF) / 255.0
        return Color(red: red, green: green, blue: blue)
    }
}
