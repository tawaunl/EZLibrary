import SwiftUI
import SeratoToolsCore

struct CrateDetailView: View {
    let node: CrateNode
    let onCratesChanged: () -> Void
    @EnvironmentObject private var libraryService: LibraryService

    @State private var isManagingTracks = false
    @State private var trackEditErrorMessage: String?
    @State private var pendingDeleteTracks: [Track] = []
    @State private var pendingDeleteCrate: Crate?
    @State private var showTrackDeleteDialog = false

    var body: some View {
        Group {
            let trackPaths = effectiveTrackPaths(for: node)
            if let crate = node.crate ?? synthesizedCrateForAggregate(node: node, trackPaths: trackPaths), !trackPaths.isEmpty {
                let resolver = TrackPathResolver(tracks: libraryService.tracks)
                let resolved = trackPaths.map { path in
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

                    TrackTableView(
                        tracks: matchedTracks,
                        numberingMode: .listOrder,
                        onDeleteRequested: { selected in
                            pendingDeleteTracks = selected
                            pendingDeleteCrate = crate
                            showTrackDeleteDialog = true
                        }
                    )

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
        .confirmationDialog(
            "Delete Selected Tracks",
            isPresented: $showTrackDeleteDialog,
            titleVisibility: .visible
        ) {
            if let pendingDeleteCrate, pendingDeleteCrate.fileURL?.pathExtension.lowercased() == "crate" {
                Button("Delete From Crate", role: .destructive) {
                    deleteSelectedTracksFromCrate()
                }
            }
            Button("Delete From Library", role: .destructive) {
                deleteSelectedTracksFromLibrary()
            }
            Button("Delete From Computer", role: .destructive) {
                deleteSelectedTracksFromComputer()
            }
            Button("Cancel", role: .cancel) {
                clearPendingTrackDelete()
            }
        } message: {
            Text("Choose how to delete \(pendingDeleteTracks.count) selected track\(pendingDeleteTracks.count == 1 ? "" : "s").")
        }
    }

    private func clearPendingTrackDelete() {
        pendingDeleteTracks = []
        pendingDeleteCrate = nil
    }

    private func deleteSelectedTracksFromCrate() {
        guard let crate = pendingDeleteCrate,
              crate.fileURL?.pathExtension.lowercased() == "crate" else {
            clearPendingTrackDelete()
            return
        }

        do {
            let removedPaths = Set(pendingDeleteTracks.map(\.seratoStoredPath))
            let rewritten = crate.trackPaths.filter { !removedPaths.contains($0) }
            _ = try SeratoCrateEditor.rewriteTrackPaths(in: crate, to: rewritten)
            clearPendingTrackDelete()
            onCratesChanged()
        } catch {
            trackEditErrorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedTracksFromLibrary() {
        do {
            let removedPaths = Set(pendingDeleteTracks.map(\.seratoStoredPath))
            try removeTracksFromLibraryMetadata(paths: removedPaths)
            clearPendingTrackDelete()
            onCratesChanged()
        } catch {
            trackEditErrorMessage = error.localizedDescription
        }
    }

    private func deleteSelectedTracksFromComputer() {
        do {
            for track in pendingDeleteTracks {
                guard FileManager.default.fileExists(atPath: track.fileURL.path) else { continue }
                _ = try FileManager.default.trashItem(at: track.fileURL, resultingItemURL: nil)
            }

            let removedPaths = Set(pendingDeleteTracks.map(\.seratoStoredPath))
            try removeTracksFromLibraryMetadata(paths: removedPaths)
            clearPendingTrackDelete()
            onCratesChanged()
        } catch {
            trackEditErrorMessage = error.localizedDescription
        }
    }

    private func removeTracksFromLibraryMetadata(paths: Set<String>) throws {
        guard !paths.isEmpty else { return }
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw SeratoPathRewriter.RewriteError.seratoIsRunning
        }

        let databaseURL = libraryService.databaseFile
        if FileManager.default.fileExists(atPath: databaseURL.path) {
            try SeratoBackupBeforeWrite.snapshot(of: databaseURL)
        }

        let databaseData = try Data(contentsOf: databaseURL)
        let rewritten = SeratoDatabaseWriter.removingPaths(paths, in: databaseData)
        if rewritten.didRewrite {
            try AtomicFileWriter.write(rewritten.data, to: databaseURL)
        }

        for crate in libraryService.crates {
            guard crate.fileURL?.pathExtension.lowercased() == "crate" else { continue }
            if crate.trackPaths.contains(where: { paths.contains($0) }) {
                let rewrittenPaths = crate.trackPaths.filter { !paths.contains($0) }
                _ = try SeratoCrateEditor.rewriteTrackPaths(in: crate, to: rewrittenPaths)
            }
        }
    }

    private func effectiveTrackPaths(for node: CrateNode) -> [String] {
        if let crate = node.crate {
            return crate.trackPaths
        }

        let pathPrefix = node.pathComponents
        let descendantCrates = (libraryService.crates + libraryService.smartCrates)
            .filter { $0.pathComponents.starts(with: pathPrefix) }

        var seen = Set<String>()
        var merged: [String] = []
        for crate in descendantCrates {
            for path in crate.trackPaths where seen.insert(path).inserted {
                merged.append(path)
            }
        }
        return merged
    }

    private func synthesizedCrateForAggregate(node: CrateNode, trackPaths: [String]) -> Crate? {
        guard !trackPaths.isEmpty else { return nil }
        return Crate(pathComponents: node.pathComponents, trackPaths: trackPaths, fileURL: nil)
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
