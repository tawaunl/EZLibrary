import SwiftUI
import Foundation
import SeratoToolsCore

struct DuplicateTracksView: View {
    @EnvironmentObject private var libraryService: LibraryService

    let onLibraryChanged: () -> Void

    @State private var searchText = ""
    @State private var duplicateGroups: [DuplicateTrackGroup] = []
    @State private var summary = DuplicateTracksSummary(totalTracks: 0, duplicateGroupCount: 0, redundantTrackCount: 0, versionSeparatedGroupCount: 0)
    @State private var keepSelectionByGroupID: [String: String] = [:]
    @State private var pendingDeletion: PendingDeletion?
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @AppStorage(Self.confirmDeletesDefaultsKey) private var confirmDeletes = true

    private static let confirmDeletesDefaultsKey = "SeratoToolsConfirmDuplicateDeletes"

    private struct PendingDeletion: Identifiable {
        let id = UUID()
        let groupLabel: String
        let keepLabel: String
        let tracks: [Track]
        let fromComputer: Bool
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                SectionHeaderCard(
                    title: "Duplicates",
                    description: "Find duplicate tracks by title and artist while keeping DJ version variants like Intro, Clean, Quick Hit, and Extended in separate groups.",
                    icon: "rectangle.on.rectangle"
                )

                summaryCard
                searchCard
                messagesBanner
                resultsCard
            }
            .padding(16)
        }
        .onAppear {
            rebuildDuplicateGroups()
        }
        .onChange(of: libraryService.tracks.count) {
            rebuildDuplicateGroups()
        }
        .onChange(of: libraryService.tracks.first?.id) {
            rebuildDuplicateGroups()
        }
        .onChange(of: libraryService.tracks.last?.id) {
            rebuildDuplicateGroups()
        }
        .confirmationDialog(
            "Delete Duplicates",
            isPresented: Binding(get: { pendingDeletion != nil }, set: { if !$0 { pendingDeletion = nil } }),
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { pending in
            Button(
                pending.fromComputer
                    ? "Move \(pending.tracks.count) File\(pending.tracks.count == 1 ? "" : "s") to Trash"
                    : "Remove \(pending.tracks.count) From Library",
                role: .destructive
            ) {
                performDeletion(pending)
            }
            Button("Cancel", role: .cancel) { pendingDeletion = nil }
        } message: { pending in
            Text(
                pending.fromComputer
                    ? "Moves \(pending.tracks.count) duplicate file\(pending.tracks.count == 1 ? "" : "s") to the Trash and removes them from the Serato library. Keeping: \(pending.keepLabel)."
                    : "Removes \(pending.tracks.count) duplicate\(pending.tracks.count == 1 ? "" : "s") from the Serato library (files stay on disk). Keeping: \(pending.keepLabel)."
            )
        }
    }

    @ViewBuilder
    private var messagesBanner: some View {
        if let successMessage {
            Text(successMessage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.green)
        }
        if let errorMessage {
            Text(errorMessage)
                .font(.callout.weight(.semibold))
                .foregroundStyle(.red)
        }
    }

    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Duplicate Summary")
                .font(.title3.weight(.semibold))

            HStack(spacing: 10) {
                statTag(title: "Tracks", value: "\(summary.totalTracks)")
                statTag(title: "Groups", value: "\(summary.duplicateGroupCount)", accent: true)
                statTag(title: "Redundant", value: "\(summary.redundantTrackCount)")
                statTag(title: "Versioned", value: "\(summary.versionSeparatedGroupCount)")
                statTag(title: "Diff Names", value: "\(differentFilenameGroupCount)")
                Spacer(minLength: 0)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private var searchCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            TextField("Search title, artist, version, or path", text: $searchText)
                .textFieldStyle(.roundedBorder)

            if duplicateGroups.isEmpty {
                Text(libraryService.tracks.isEmpty ? "Load a library first to scan for duplicates." : "No duplicate groups found.")
                    .foregroundStyle(.secondary)
            } else {
                Text("\(filteredGroups.count) groups match the current search.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private var resultsCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Duplicate Groups")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 0)
                Toggle("Confirm Deletes", isOn: $confirmDeletes)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .help("When off, delete actions run immediately without a confirmation prompt.")
            }

            if !filteredGroups.isEmpty {
                bulkActionsBar
            }

            if filteredGroups.isEmpty {
                Text(duplicateGroups.isEmpty ? "No duplicate groups detected in the current library." : "No duplicate groups matched your search.")
                    .foregroundStyle(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(filteredGroups) { group in
                        groupCard(for: group)
                    }
                }
            }
        }
        .padding(16)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
    }

    private var bulkActionsBar: some View {
        let totalDeletable = filteredGroups.reduce(0) { $0 + deletableTracks(for: $1).count }
        return HStack(spacing: 8) {
            Button("Pick Best (All)") {
                pickBestForAll()
            }
            .help("Select the most complete copy (oldest on ties) to keep in every group.")

            Button("Delete All Others → Library") {
                requestMassDeletion(fromComputer: false)
            }
            .disabled(totalDeletable == 0)

            Button("Delete All Others → Computer") {
                requestMassDeletion(fromComputer: true)
            }
            .disabled(totalDeletable == 0)

            Text("\(totalDeletable) removable")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private func groupCard(for group: DuplicateTrackGroup) -> some View {
        let best = DuplicateTracksService.bestTrack(in: group.tracks)
        let kept = keptPath(for: group)
        let deletable = deletableTracks(for: group)

        return VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(group.artist) - \(group.title)")
                        .font(.headline)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text("Version: \(group.versionLabel)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(group.hasDifferentFilenames ? "Different filenames" : "Same filename")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(
                                Capsule().fill((group.hasDifferentFilenames ? Color.orange : Color.green).opacity(0.16))
                            )
                            .foregroundStyle(group.hasDifferentFilenames ? Color.orange : Color.green)
                    }
                }

                Spacer(minLength: 0)

                statTag(title: "Tracks", value: "\(group.trackCount)", accent: true)
                statTag(title: "Redundant", value: "\(group.redundantTrackCount)")
            }

            groupActionBar(group: group, best: best, deletable: deletable)

            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.tracks) { track in
                    trackRow(track: track, group: group, keptPath: kept, best: best)
                }
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.66))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.secondary.opacity(0.18), lineWidth: 1)
        )
    }

    private func groupActionBar(group: DuplicateTrackGroup, best: Track?, deletable: [Track]) -> some View {
        HStack(spacing: 8) {
            Button("Pick Best") {
                if let best {
                    keepSelectionByGroupID[group.id] = best.seratoStoredPath
                }
            }
            .help("Keep the copy with the most complete tags; ties keep the oldest by date added.")

            Button("Delete Others → Library") {
                requestDeletion(group: group, tracks: deletable, fromComputer: false)
            }
            .disabled(deletable.isEmpty)

            Button("Delete Others → Computer") {
                requestDeletion(group: group, tracks: deletable, fromComputer: true)
            }
            .disabled(deletable.isEmpty)

            Spacer(minLength: 0)
        }
    }

    private func trackRow(track: Track, group: DuplicateTrackGroup, keptPath: String?, best: Track?) -> some View {
        let isKept = track.seratoStoredPath == keptPath
        let isBest = track.id == best?.id
        let tagCount = DuplicateTracksService.completenessScore(for: track)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Text(track.title.isEmpty ? track.fileURL.deletingPathExtension().lastPathComponent : track.title)
                    .font(.subheadline)
                Text(DuplicateTracksService.versionLabel(for: track))
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Capsule().fill(Color.accentColor.opacity(0.15)))

                if isBest {
                    Text("Best")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.18)))
                        .foregroundStyle(.green)
                }

                Spacer(minLength: 0)

                Text("Tags: \(tagCount)")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)

                if isKept {
                    Text("Keep")
                        .font(.caption2.weight(.bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(Color.green.opacity(0.22)))
                        .foregroundStyle(.green)
                } else {
                    Button("Keep This") {
                        keepSelectionByGroupID[group.id] = track.seratoStoredPath
                    }
                    .controlSize(.small)
                }
            }
            Text(track.artist.isEmpty ? track.fileURL.lastPathComponent : track.artist)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("File: \(track.fileURL.lastPathComponent)")
                .font(.caption2.weight(.medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let dateAdded = track.dateAdded {
                Text("Added: \(dateAdded.formatted(date: .abbreviated, time: .omitted))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Text(track.fileURL.path)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(nsColor: .windowBackgroundColor).opacity(0.55))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isKept ? Color.green.opacity(0.55) : Color.clear, lineWidth: 1)
        )
    }

    private var filteredGroups: [DuplicateTrackGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return duplicateGroups }

        return duplicateGroups.filter { group in
            if group.artist.lowercased().contains(query) { return true }
            if group.title.lowercased().contains(query) { return true }
            if group.versionLabel.lowercased().contains(query) { return true }
            return group.tracks.contains { track in
                track.title.lowercased().contains(query)
                    || track.artist.lowercased().contains(query)
                    || track.fileURL.path.lowercased().contains(query)
            }
        }
    }

    private var differentFilenameGroupCount: Int {
        duplicateGroups.filter { $0.hasDifferentFilenames }.count
    }

    private func rebuildDuplicateGroups() {
        duplicateGroups = DuplicateTracksService.duplicateGroups(in: libraryService.tracks)
        summary = DuplicateTracksService.summary(for: libraryService.tracks)
        keepSelectionByGroupID = keepSelectionByGroupID.filter { key, _ in
            duplicateGroups.contains { $0.id == key }
        }
    }

    private func keptPath(for group: DuplicateTrackGroup) -> String? {
        keepSelectionByGroupID[group.id] ?? DuplicateTracksService.bestTrack(in: group.tracks)?.seratoStoredPath
    }

    private func deletableTracks(for group: DuplicateTrackGroup) -> [Track] {
        let kept = keptPath(for: group)
        return group.tracks.filter { $0.seratoStoredPath != kept }
    }

    private func pickBestForAll() {
        for group in filteredGroups {
            if let best = DuplicateTracksService.bestTrack(in: group.tracks) {
                keepSelectionByGroupID[group.id] = best.seratoStoredPath
            }
        }
    }

    private func requestDeletion(group: DuplicateTrackGroup, tracks: [Track], fromComputer: Bool) {
        guard !tracks.isEmpty else { return }
        let keptTrack = group.tracks.first { $0.seratoStoredPath == keptPath(for: group) }
        let keepLabel = keptTrack.map { $0.fileURL.lastPathComponent } ?? group.title

        confirmOrPerform(
            PendingDeletion(
                groupLabel: "\(group.artist) - \(group.title)",
                keepLabel: keepLabel,
                tracks: tracks,
                fromComputer: fromComputer
            )
        )
    }

    private func requestMassDeletion(fromComputer: Bool) {
        let tracks = filteredGroups.flatMap { deletableTracks(for: $0) }
        guard !tracks.isEmpty else { return }

        confirmOrPerform(
            PendingDeletion(
                groupLabel: "\(filteredGroups.count) groups",
                keepLabel: "the best copy in each group",
                tracks: tracks,
                fromComputer: fromComputer
            )
        )
    }

    private func confirmOrPerform(_ pending: PendingDeletion) {
        if confirmDeletes {
            pendingDeletion = pending
        } else {
            performDeletion(pending)
        }
    }

    private func performDeletion(_ pending: PendingDeletion) {
        pendingDeletion = nil
        successMessage = nil
        errorMessage = nil

        let deletePaths = Set(pending.tracks.map(\.seratoStoredPath))

        do {
            var trashedCount = 0
            if pending.fromComputer {
                // Never trash a physical file that a surviving library entry
                // still references (e.g. two DB entries pointing at one file).
                let retainedFilePaths = Set(
                    libraryService.tracks
                        .filter { !deletePaths.contains($0.seratoStoredPath) }
                        .map { $0.fileURL.standardizedFileURL.path }
                )

                for track in pending.tracks {
                    let filePath = track.fileURL.standardizedFileURL.path
                    guard FileManager.default.fileExists(atPath: filePath) else { continue }
                    if retainedFilePaths.contains(filePath) { continue }
                    _ = try FileManager.default.trashItem(at: track.fileURL, resultingItemURL: nil)
                    trashedCount += 1
                }
            }

            try removeFromLibraryMetadata(paths: deletePaths)
            onLibraryChanged()
            rebuildDuplicateGroups()

            let count = pending.tracks.count
            successMessage = pending.fromComputer
                ? "Moved \(trashedCount) file\(trashedCount == 1 ? "" : "s") to Trash and removed \(count) duplicate\(count == 1 ? "" : "s") from the library."
                : "Removed \(count) duplicate\(count == 1 ? "" : "s") from the library."
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func removeFromLibraryMetadata(paths: Set<String>) throws {
        guard !paths.isEmpty else { return }

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

    private func statTag(title: String, value: String, accent: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.footnote)
                .foregroundStyle(accent ? .white.opacity(0.92) : .secondary)
            Text(value)
                .font(.system(size: 24, weight: .semibold, design: .default))
                .monospacedDigit()
                .foregroundStyle(accent ? .white : .primary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(accent ? Color.accentColor.opacity(0.92) : Color(nsColor: .windowBackgroundColor))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(accent ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: 1)
        )
    }
}