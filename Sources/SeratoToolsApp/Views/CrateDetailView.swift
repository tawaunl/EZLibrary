import SwiftUI
import SeratoToolsCore

struct CrateDetailView: View {
    let node: CrateNode
    let onCratesChanged: () -> Void
    @EnvironmentObject private var libraryService: LibraryService

    @State private var isManagingTracks = false
    @State private var trackEditErrorMessage: String?

    var body: some View {
        Group {
            if let crate = node.crate {
                let resolver = TrackPathResolver(tracks: libraryService.tracks)
                let resolved = crate.trackPaths.map { path in
                    (path: path, track: resolver.resolve(path: path))
                }
                let matchedTracks = resolved.compactMap(\.track)
                let unmatchedPaths = resolved.compactMap { $0.track == nil ? $0.path : nil }
                let isEditableCrate = crate.fileURL?.pathExtension.lowercased() == "crate"

                VStack(alignment: .leading, spacing: 0) {
                    if isEditableCrate {
                        HStack {
                            Button("Manage Tracks") {
                                isManagingTracks = true
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 8)
                        .padding(.top, 8)
                    }

                    TrackTableView(tracks: matchedTracks, numberingMode: .listOrder)

                    // Confirmed to happen legitimately for some Smart Crate
                    // entries referencing a different Serato profile/volume
                    // context — shown separately rather than as an error.
                    if !unmatchedPaths.isEmpty {
                        Divider()
                        DisclosureGroup("Not in local library (\(unmatchedPaths.count))") {
                            ForEach(unmatchedPaths, id: \.self) { path in
                                Text(path)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .padding()
                    }
                }
            } else {
                ContentUnavailableView(
                    "No Tracks",
                    systemImage: "folder",
                    description: Text("This groups nested crates — select one of its children to see tracks.")
                )
            }
        }
        .sheet(isPresented: $isManagingTracks) {
            if let crate = node.crate {
                CrateTrackManagerView(crate: crate, libraryTracks: libraryService.tracks) {
                    onCratesChanged()
                }
            }
        }
        .alert(
            "Couldn't Update Crate",
            isPresented: Binding(get: { trackEditErrorMessage != nil }, set: { if !$0 { trackEditErrorMessage = nil } })
        ) {
            Button("OK") { trackEditErrorMessage = nil }
        } message: {
            Text(trackEditErrorMessage ?? "")
        }
    }
}

private struct TrackPathResolver {
    private let exactByNormalizedPath: [String: Track]
    private let byFilename: [String: [Track]]

    init(tracks: [Track]) {
        exactByNormalizedPath = Dictionary(
            tracks.map { (Self.normalize(path: $0.seratoStoredPath), $0) },
            uniquingKeysWith: { first, _ in first }
        )
        byFilename = Dictionary(grouping: tracks, by: {
            $0.fileURL.lastPathComponent.lowercased()
        })
    }

    func resolve(path: String) -> Track? {
        let normalized = Self.normalize(path: path)
        if let exact = exactByNormalizedPath[normalized] {
            return exact
        }

        // Smart crates can reference legacy profile-specific absolute-like
        // paths (e.g. Users/.../All Music/track.mp3) that no longer match
        // current `database V2` stored paths. Fall back to filename only
        // when it maps to a unique library track to avoid wrong matches.
        let filename = URL(fileURLWithPath: path).lastPathComponent.lowercased()
        guard let candidates = byFilename[filename], candidates.count == 1 else {
            return nil
        }
        return candidates[0]
    }

    private static func normalize(path: String) -> String {
        path
            .replacingOccurrences(of: "\\\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}

private struct CrateTrackManagerView: View {
    @Environment(\.dismiss) private var dismiss

    let crate: Crate
    let libraryTracks: [Track]
    let onSaved: () -> Void

    @State private var searchText = ""
    @State private var workingPaths: [String]
    @State private var saveErrorMessage: String?

    init(crate: Crate, libraryTracks: [Track], onSaved: @escaping () -> Void) {
        self.crate = crate
        self.libraryTracks = libraryTracks
        self.onSaved = onSaved
        _workingPaths = State(initialValue: crate.trackPaths)
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Manage Tracks: \(crate.name)")
                    .font(.headline)
                Spacer()
            }

            TextField("Search library tracks", text: $searchText)
                .textFieldStyle(.roundedBorder)

            List(filteredTracks, id: \.id) { track in
                HStack {
                    VStack(alignment: .leading) {
                        Text(track.title.isEmpty ? track.fileURL.lastPathComponent : track.title)
                        Text(track.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button(isIncluded(track.seratoStoredPath) ? "Remove" : "Add") {
                        toggle(track.seratoStoredPath)
                    }
                }
            }

            HStack {
                Text("\(workingPaths.count) track\(workingPaths.count == 1 ? "" : "s") in crate")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Save") { save() }
            }
        }
        .padding()
        .frame(minWidth: 700, minHeight: 500)
        .alert(
            "Couldn't Save Crate",
            isPresented: Binding(get: { saveErrorMessage != nil }, set: { if !$0 { saveErrorMessage = nil } })
        ) {
            Button("OK") { saveErrorMessage = nil }
        } message: {
            Text(saveErrorMessage ?? "")
        }
    }

    private var filteredTracks: [Track] {
        if searchText.isEmpty {
            return libraryTracks
        }
        return libraryTracks.filter {
            $0.title.localizedCaseInsensitiveContains(searchText)
            || $0.artist.localizedCaseInsensitiveContains(searchText)
            || $0.album.localizedCaseInsensitiveContains(searchText)
            || $0.fileURL.lastPathComponent.localizedCaseInsensitiveContains(searchText)
        }
    }

    private func isIncluded(_ path: String) -> Bool {
        workingPaths.contains(path)
    }

    private func toggle(_ path: String) {
        if let index = workingPaths.firstIndex(of: path) {
            workingPaths.remove(at: index)
        } else {
            workingPaths.append(path)
        }
    }

    private func save() {
        do {
            _ = try SeratoCrateEditor.rewriteTrackPaths(in: crate, to: workingPaths)
            onSaved()
            dismiss()
        } catch {
            saveErrorMessage = error.localizedDescription
        }
    }
}
