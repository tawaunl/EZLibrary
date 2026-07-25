// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import SwiftUI
import Foundation
import EZLibraryCore

/// Carries fingerprint scan progress back to the UI.
///
/// `AudioFingerprintExtractor` reports from its worker tasks, so the callback
/// needs a `Sendable` destination — a `@MainActor` object is implicitly one,
/// and republishes on the main actor for SwiftUI.
@MainActor
final class FingerprintScanProgress: ObservableObject {
    @Published var completed = 0
    @Published var total = 0

    var fraction: Double {
        total > 0 ? Double(completed) / Double(total) : 0
    }

    func reset(total: Int) {
        completed = 0
        self.total = total
    }
}

struct DuplicateTracksView: View {
    @EnvironmentObject private var libraryService: LibraryService

    let onLibraryChanged: () -> Void

    @State private var searchText = ""
    @State private var duplicateGroups: [DuplicateTrackGroup] = []
    @State private var summary = DuplicateTracksSummary(totalTracks: 0, duplicateGroupCount: 0, redundantTrackCount: 0, versionSeparatedGroupCount: 0)
    @State private var keepSelectionByGroupID: [String: String] = [:]
    /// Recommended keep per group, computed once per scan — `bestTrack(in:)`
    /// re-ranks the group every call, and it was being invoked per group per
    /// render (and across all groups for the bulk-action counts).
    @State private var bestPathByGroupID: [String: String] = [:]
    @State private var isScanning = false
    @State private var rebuildTask: Task<Void, Never>?

    /// Fingerprint verdicts from the last audio scan, keyed by group ID.
    /// Empty until the user runs one — groups are metadata matches by default.
    @State private var audioStatusByGroupID: [String: FingerprintStatus] = [:]
    /// Sibling version labels per group, so a card can say which versions the
    /// scan deliberately kept out of this group.
    @State private var relatedVersionsByGroupID: [String: [String]] = [:]
    /// Groups whose copies are similar but not bit-identical.
    @State private var needsListenByGroupID: [String: Bool] = [:]
    @State private var isVerifyingAudio = false
    @State private var verifyTask: Task<Void, Never>?
    @State private var audioScanSummary: String?
    @State private var audioScanPhase: FingerprintLibraryScanService.ScanPhase = .fingerprinting
    @StateObject private var audioProgress = FingerprintScanProgress()
    @State private var pendingDeletion: PendingDeletion?
    @State private var errorMessage: String?
    @State private var successMessage: String?
    @AppStorage(Self.confirmDeletesDefaultsKey) private var confirmDeletes = true

    /// Shared player for auditioning copies. One player, not one per row, so
    /// starting a copy stops whatever was playing.
    @StateObject private var auditionPlayer = TrackAudioPlayerViewModel()
    /// Stored path of the copy currently loaded for audition, if any.
    @State private var auditioningPath: String?
    /// Group the audition belongs to, so only that card shows the transport.
    @State private var auditioningGroupID: String?

    /// Ignored indefinitely (persisted). Cleared only from the manage section.
    @StateObject private var ignoreStore = DuplicateIgnoreStore()
    /// Ignored just for this session ("ignore this time"); cleared on relaunch.
    @State private var sessionIgnoredGroupIDs: Set<String> = []
    @State private var sessionIgnoredTrackPaths: Set<String> = []

    private static let confirmDeletesDefaultsKey = "SeratoToolsConfirmDuplicateDeletes"

    private struct PendingDeletion: Identifiable {
        let id = UUID()
        let groupLabel: String
        let keepLabel: String
        let tracks: [Track]
        let fromComputer: Bool
        /// Deleted stored path → the copy that survives it, so crate entries
        /// can be re-pointed instead of dropped.
        let keptPathByDeletedPath: [String: String]
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
                audioVerificationCard
                searchCard
                messagesBanner
                resultsCard
                ignoredItemsCard
            }
            .padding(16)
        }
        .onAppear {
            rebuildDuplicateGroups()
        }
        .onDisappear {
            stopAudition()
        }
        .onReceive(Timer.publish(every: 0.12, on: .main, in: .common).autoconnect()) { _ in
            guard auditioningPath != nil else { return }
            auditionPlayer.refreshProgress()
        }
        // Ignoring a copy (or its group) hides the row, so stop playing it.
        .onChange(of: sessionIgnoredTrackPaths) { stopAuditionIfTrackVanished() }
        .onChange(of: sessionIgnoredGroupIDs) { stopAuditionIfTrackVanished() }
        .onChange(of: ignoreStore.ignoredTrackPaths) { stopAuditionIfTrackVanished() }
        .onChange(of: ignoreStore.ignoredGroupIDs) { stopAuditionIfTrackVanished() }
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

    @ViewBuilder
    private var ignoredItemsCard: some View {
        if hasAnyIgnores {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Text("Ignored Items")
                        .font(.title3.weight(.semibold))
                    Spacer(minLength: 0)
                    if hasSessionIgnores {
                        Button("Clear This Session") {
                            sessionIgnoredGroupIDs.removeAll()
                            sessionIgnoredTrackPaths.removeAll()
                        }
                        .controlSize(.small)
                        .help("Un-ignore everything ignored 'this time'. Indefinite ignores stay.")
                    }
                    if hasIndefiniteIgnores {
                        Button("Restore All Indefinite") {
                            ignoreStore.restoreAll()
                        }
                        .controlSize(.small)
                        .help("Un-ignore every group and song ignored indefinitely.")
                    }
                }

                if hasSessionIgnores {
                    Text("This session: \(sessionIgnoredGroupIDs.count) group\(sessionIgnoredGroupIDs.count == 1 ? "" : "s"), \(sessionIgnoredTrackPaths.count) song\(sessionIgnoredTrackPaths.count == 1 ? "" : "s") hidden until relaunch.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if !ignoreStore.ignoredGroupIDs.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Groups ignored indefinitely (\(ignoreStore.ignoredGroupIDs.count))")
                            .font(.subheadline.weight(.semibold))
                        ForEach(ignoreStore.ignoredGroupIDs.sorted(), id: \.self) { groupID in
                            HStack(spacing: 8) {
                                Text(groupLabel(forID: groupID))
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Button("Restore") { ignoreStore.restoreGroup(groupID) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }

                if !ignoreStore.ignoredTrackPaths.isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Songs ignored indefinitely (\(ignoreStore.ignoredTrackPaths.count))")
                            .font(.subheadline.weight(.semibold))
                        ForEach(ignoreStore.ignoredTrackPaths.sorted(), id: \.self) { storedPath in
                            HStack(spacing: 8) {
                                Text(trackLabel(forPath: storedPath))
                                    .font(.callout)
                                    .lineLimit(1)
                                Spacer(minLength: 0)
                                Button("Restore") { ignoreStore.restoreTrack(storedPath) }
                                    .controlSize(.small)
                            }
                        }
                    }
                }
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color(nsColor: .controlBackgroundColor).opacity(0.55)))
        }
    }

    private var hasSessionIgnores: Bool {
        !sessionIgnoredGroupIDs.isEmpty || !sessionIgnoredTrackPaths.isEmpty
    }

    private var hasIndefiniteIgnores: Bool {
        !ignoreStore.ignoredGroupIDs.isEmpty || !ignoreStore.ignoredTrackPaths.isEmpty
    }

    private var hasAnyIgnores: Bool {
        hasSessionIgnores || hasIndefiniteIgnores
    }

    private func groupLabel(forID groupID: String) -> String {
        if let group = duplicateGroups.first(where: { $0.id == groupID }) {
            return "\(group.artist) - \(group.title) (\(group.versionLabel))"
        }
        return groupID
    }

    private func trackLabel(forPath storedPath: String) -> String {
        if let track = libraryService.tracks.first(where: { $0.seratoStoredPath == storedPath }) {
            let title = track.title.isEmpty ? track.fileURL.lastPathComponent : track.title
            return track.artist.isEmpty ? title : "\(track.artist) - \(title)"
        }
        return (storedPath as NSString).lastPathComponent
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

    private var isFingerprintingAvailable: Bool {
        AudioFingerprintService.fpcalcExecutablePath() != nil
    }

    private var audioVerificationCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Text("Verify by Audio")
                    .font(.title3.weight(.semibold))
                Spacer(minLength: 0)

                if isVerifyingAudio {
                    Button("Cancel") {
                        verifyTask?.cancel()
                        isVerifyingAudio = false
                    }
                    .controlSize(.small)
                } else {
                    Button("Verify Groups") {
                        verifyWithAudio()
                    }
                    .controlSize(.small)
                    .disabled(duplicateGroups.isEmpty || isScanning || !isFingerprintingAvailable)
                    .help("Fingerprint the groups found above to confirm each one, splitting tracks that only share tags.")

                    Button("Scan Whole Library") {
                        scanLibraryByAudio()
                    }
                    .controlSize(.small)
                    .buttonStyle(.borderedProminent)
                    .disabled(libraryService.tracks.count < 2 || isScanning || !isFingerprintingAvailable)
                    .help("Fingerprint every track and group by sound alone. Finds duplicates whose tags don't match at all. The first run reads every file; later scans reuse saved fingerprints.")
                }
            }

            Text("Compares how tracks actually sound. \"Verify Groups\" checks the groups found above; \"Scan Whole Library\" ignores tags entirely, so it also finds copies whose artist and title don't match.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if !isFingerprintingAvailable {
                Text("Requires the fpcalc scanner. Install it with: brew install chromaprint")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }

            if isVerifyingAudio {
                VStack(alignment: .leading, spacing: 4) {
                    if audioScanPhase == .matching {
                        ProgressView()
                            .controlSize(.small)
                        Text("Comparing fingerprints…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        ProgressView(value: audioProgress.fraction)
                        Text(audioProgress.total > 0
                             ? "Reading audio \(audioProgress.completed) of \(audioProgress.total)…"
                             : "Preparing…")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if let audioScanSummary {
                Text(audioScanSummary)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(.green)
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
                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Scanning for duplicates…")
                            .foregroundStyle(.secondary)
                    }
                } else {
                    Text(duplicateGroups.isEmpty ? "No duplicate groups detected in the current library." : "No duplicate groups matched your search.")
                        .foregroundStyle(.secondary)
                }
            } else {
                // Lazy so a library with thousands of duplicate groups only
                // builds the cards that scroll into view.
                LazyVStack(alignment: .leading, spacing: 10) {
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
            .help("Across every group, remove all copies except the kept one from the Serato library. Files stay on disk.")

            Button("Delete All Others → Computer") {
                requestMassDeletion(fromComputer: true)
            }
            .disabled(totalDeletable == 0)
            .help("Across every group, remove all copies except the kept one and move their files to the Trash.")

            Text("\(totalDeletable) removable")
                .font(.caption)
                .foregroundStyle(.secondary)

            Spacer(minLength: 0)
        }
    }

    private func groupCard(for group: DuplicateTrackGroup) -> some View {
        let bestPath = bestPathByGroupID[group.id]
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

                        if let status = audioStatusByGroupID[group.id] {
                            audioStatusBadge(status)
                        }
                    }

                    if let versions = relatedVersionsByGroupID[group.id], !versions.isEmpty {
                        Label(
                            "Other versions kept safe: \(versions.joined(separator: ", "))",
                            systemImage: "arrow.triangle.branch"
                        )
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .help("This track also exists in these versions. They're never grouped with this one, so deleting here can't remove them.")
                    }

                    if needsListenByGroupID[group.id] == true {
                        Label(
                            "Close but not identical — listen before deleting",
                            systemImage: "exclamationmark.triangle"
                        )
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.orange)
                        .help("These copies share a version label and sound alike, but aren't bit-identical. They aren't pre-selected for deletion.")
                    }
                }

                Spacer(minLength: 0)

                statTag(title: "Tracks", value: "\(group.trackCount)", accent: true)
                statTag(title: "Redundant", value: "\(group.redundantTrackCount)")
            }

            groupActionBar(group: group, bestPath: bestPath, deletable: deletable)

            if auditioningGroupID == group.id {
                auditionTransport(for: group)
            }

            VStack(alignment: .leading, spacing: 6) {
                ForEach(group.tracks) { track in
                    trackRow(track: track, group: group, keptPath: kept, bestPath: bestPath)
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

    private func audioStatusBadge(_ status: FingerprintStatus) -> some View {
        let color: Color = status.isConfirmed ? .blue : .secondary
        return Text(status.badgeText)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(color.opacity(0.16)))
            .foregroundStyle(color)
            .help(audioStatusHelp(status))
    }

    private func audioStatusHelp(_ status: FingerprintStatus) -> String {
        switch status {
        case .audioConfirmed:
            return "Every track in this group was fingerprinted and they are the same recording."
        case let .audioConfirmedSubset(originalTrackCount):
            return "Audio fingerprinting split a group of \(originalTrackCount) tracks. These are the same recording as each other."
        case .audioOnlyMatch:
            return "Same recording, but the tags disagree — matching on artist and title alone would never have found this group."
        case let .unverified(reason):
            return "Matched on tags only — \(reason)"
        }
    }

    private func groupActionBar(group: DuplicateTrackGroup, bestPath: String?, deletable: [Track]) -> some View {
        HStack(spacing: 8) {
            Button("Pick Best") {
                if let bestPath {
                    keepSelectionByGroupID[group.id] = bestPath
                }
            }
            .help("Keep the copy with the most complete tags; ties keep the oldest by date added.")

            Button("Delete Others → Library") {
                requestDeletion(group: group, tracks: deletable, fromComputer: false)
            }
            .disabled(deletable.isEmpty)
            .help("Remove the other copies in this group from the Serato library. Files stay on disk.")

            Button("Delete Others → Computer") {
                requestDeletion(group: group, tracks: deletable, fromComputer: true)
            }
            .disabled(deletable.isEmpty)
            .help("Remove the other copies in this group and move their files to the Trash.")

            Menu("Ignore Group") {
                Button("Ignore This Time") {
                    sessionIgnoredGroupIDs.insert(group.id)
                }
                Button("Ignore Indefinitely") {
                    ignoreStore.ignoreGroup(group.id)
                }
            }
            .frame(maxWidth: 150)
            .help("Skip this group so it isn't shown or deleted. 'This time' clears on relaunch; 'indefinitely' persists until restored.")

            Spacer(minLength: 0)
        }
    }

    private func trackRow(track: Track, group: DuplicateTrackGroup, keptPath: String?, bestPath: String?) -> some View {
        let isKept = track.seratoStoredPath == keptPath
        let isBest = track.seratoStoredPath == bestPath
        let tagCount = DuplicateTracksService.completenessScore(for: track)

        let isAuditioningThis = isAuditioning(track)

        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Button {
                    toggleAudition(of: track, in: group)
                } label: {
                    Image(systemName: isAuditioningThis && auditionPlayer.isPlaying
                          ? "pause.circle.fill"
                          : "play.circle")
                        .foregroundStyle(isAuditioningThis ? Color.accentColor : Color.secondary)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .disabled(track.isMissing)
                .help(track.isMissing
                      ? "This file is missing on disk."
                      : "Listen to this copy. Switching copies keeps your place, so you can compare the same moment.")

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
                    .help("Keep this copy and mark the others in the group for deletion.")
                }

                Menu {
                    Button("Ignore This Time") {
                        sessionIgnoredTrackPaths.insert(track.seratoStoredPath)
                    }
                    Button("Ignore Indefinitely") {
                        ignoreStore.ignoreTrack(track.seratoStoredPath)
                    }
                } label: {
                    Image(systemName: "eye.slash")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .controlSize(.small)
                .help("Ignore just this copy so it isn't shown or deleted. 'This time' clears on relaunch; 'indefinitely' persists until restored.")
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
        guard !query.isEmpty else { return visibleGroups }

        return visibleGroups.filter { group in
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

    /// Duplicate groups with ignored groups removed and ignored tracks stripped
    /// out. A group that drops below two tracks after removing ignored ones is
    /// no longer a duplicate, so it's hidden too.
    private var visibleGroups: [DuplicateTrackGroup] {
        duplicateGroups.compactMap { group in
            if isGroupIgnored(group.id) { return nil }

            let remaining = group.tracks.filter { !isTrackIgnored($0.seratoStoredPath) }
            guard remaining.count > 1 else { return nil }
            if remaining.count == group.tracks.count { return group }

            return DuplicateTrackGroup(
                id: group.id,
                artist: group.artist,
                title: group.title,
                versionLabel: group.versionLabel,
                tracks: remaining
            )
        }
    }

    private func isGroupIgnored(_ groupID: String) -> Bool {
        ignoreStore.isGroupIgnored(groupID) || sessionIgnoredGroupIDs.contains(groupID)
    }

    private func isTrackIgnored(_ storedPath: String) -> Bool {
        ignoreStore.isTrackIgnored(storedPath) || sessionIgnoredTrackPaths.contains(storedPath)
    }

    private var differentFilenameGroupCount: Int {
        duplicateGroups.filter { $0.hasDifferentFilenames }.count
    }

    private func rebuildDuplicateGroups() {
        let tracks = libraryService.tracks
        rebuildTask?.cancel()
        isScanning = true
        // The duplicate scan normalizes every track's title/artist — run it
        // off the main actor so opening this tab doesn't freeze the app.
        rebuildTask = Task {
            let (groups, groupSummary, bestPaths) = await Task.detached(priority: .userInitiated) {
                () -> ([DuplicateTrackGroup], DuplicateTracksSummary, [String: String]) in
                let groups = DuplicateTracksService.duplicateGroups(in: tracks)
                let summary = DuplicateTracksService.summary(forGroups: groups, totalTracks: tracks.count)
                var bestPaths: [String: String] = [:]
                for group in groups {
                    bestPaths[group.id] = DuplicateTracksService.bestTrack(in: group.tracks)?.seratoStoredPath
                }
                return (groups, summary, bestPaths)
            }.value

            guard !Task.isCancelled else { return }
            duplicateGroups = groups
            summary = groupSummary
            bestPathByGroupID = bestPaths
            let groupIDs = Set(groups.map(\.id))
            keepSelectionByGroupID = keepSelectionByGroupID.filter { key, _ in
                groupIDs.contains(key)
            }
            // A fresh metadata scan invalidates the previous audio verdicts —
            // never carry a stale "verified" badge onto a regrouped library.
            audioStatusByGroupID = [:]
            relatedVersionsByGroupID = [:]
            needsListenByGroupID = [:]
            audioScanSummary = nil
            isScanning = false
        }
    }

    /// Confirms the metadata groups against the actual audio, splitting groups
    /// whose tracks only share tags and dropping tracks that aren't duplicates.
    private func verifyWithAudio() {
        guard !duplicateGroups.isEmpty else { return }

        verifyTask?.cancel()
        isVerifyingAudio = true
        audioScanSummary = nil
        errorMessage = nil

        let groups = duplicateGroups
        let progress = audioProgress
        // Only duration-compatible tracks get fingerprinted, so the bar is
        // seeded with the upper bound and corrected on the first callback.
        progress.reset(total: groups.reduce(0) { $0 + $1.tracks.count })

        verifyTask = Task {
            do {
                let result = try await FingerprintDuplicateService.verify(
                    groups: groups,
                    progress: { completed, total in
                        Task { @MainActor in
                            progress.completed = completed
                            progress.total = total
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                let verifiedGroups = result.groups.map(\.group)
                duplicateGroups = verifiedGroups
                audioStatusByGroupID = Dictionary(
                    uniqueKeysWithValues: result.groups.map { ($0.id, $0.status) }
                )
                relatedVersionsByGroupID = Dictionary(
                    uniqueKeysWithValues: result.groups.map { ($0.id, $0.relatedVersions) }
                )
                needsListenByGroupID = Dictionary(
                    uniqueKeysWithValues: result.groups.map { ($0.id, $0.needsListenBeforeDeleting) }
                )
                summary = DuplicateTracksService.summary(
                    forGroups: verifiedGroups,
                    totalTracks: summary.totalTracks
                )
                bestPathByGroupID = Dictionary(
                    uniqueKeysWithValues: verifiedGroups.compactMap { group in
                        DuplicateTracksService.bestTrack(in: group.tracks)
                            .map { (group.id, $0.seratoStoredPath) }
                    }
                )
                // Group IDs change when audio splits a group, so stale keep
                // selections would point at groups that no longer exist.
                let ids = Set(verifiedGroups.map(\.id))
                keepSelectionByGroupID = keepSelectionByGroupID.filter { ids.contains($0.key) }

                audioScanSummary = summaryText(for: result)
                isVerifyingAudio = false
            } catch is CancellationError {
                isVerifyingAudio = false
            } catch {
                errorMessage = error.localizedDescription
                isVerifyingAudio = false
            }
        }
    }

    /// Scans every track's audio, ignoring tags entirely.
    ///
    /// This is the only pass that can find copies whose tags disagree, since
    /// metadata grouping never puts those tracks together in the first place.
    private func scanLibraryByAudio() {
        let tracks = libraryService.tracks
        guard tracks.count > 1 else { return }

        verifyTask?.cancel()
        isVerifyingAudio = true
        audioScanSummary = nil
        errorMessage = nil
        audioScanPhase = .fingerprinting

        let progress = audioProgress
        progress.reset(total: tracks.count)

        verifyTask = Task {
            do {
                let result = try await FingerprintLibraryScanService.scan(
                    tracks: tracks,
                    // The whole library is in scope here, so trimming cached
                    // fingerprints for files that are gone is safe.
                    pruneCacheToTracks: true,
                    progress: { phase, done, total in
                        Task { @MainActor in
                            audioScanPhase = phase
                            if total > 0 {
                                progress.completed = done
                                progress.total = total
                            }
                        }
                    }
                )

                guard !Task.isCancelled else { return }

                let scannedGroups = result.groups.map(\.group)
                duplicateGroups = scannedGroups
                audioStatusByGroupID = Dictionary(
                    uniqueKeysWithValues: result.groups.map { ($0.id, $0.status) }
                )
                relatedVersionsByGroupID = Dictionary(
                    uniqueKeysWithValues: result.groups.map { ($0.id, $0.relatedVersions) }
                )
                needsListenByGroupID = Dictionary(
                    uniqueKeysWithValues: result.groups.map { ($0.id, $0.needsListenBeforeDeleting) }
                )
                summary = DuplicateTracksService.summary(
                    forGroups: scannedGroups,
                    totalTracks: tracks.count
                )
                bestPathByGroupID = Dictionary(
                    uniqueKeysWithValues: scannedGroups.compactMap { group in
                        DuplicateTracksService.bestTrack(in: group.tracks)
                            .map { (group.id, $0.seratoStoredPath) }
                    }
                )
                keepSelectionByGroupID = [:]
                audioScanSummary = scanSummaryText(for: result)
                isVerifyingAudio = false
            } catch is CancellationError {
                // Fingerprints computed before cancelling are already saved,
                // so resuming later picks up where this left off.
                audioScanSummary = "Scan cancelled. Progress so far was saved."
                isVerifyingAudio = false
            } catch {
                errorMessage = error.localizedDescription
                isVerifyingAudio = false
            }
        }
    }

    private func scanSummaryText(for result: LibraryFingerprintScanResult) -> String {
        guard !result.groups.isEmpty else {
            return "Scanned \(result.scannedTrackCount) tracks — no duplicate audio found."
        }

        var text = "Found \(result.groups.count) group\(result.groups.count == 1 ? "" : "s") across \(result.scannedTrackCount) tracks"
        if result.tagMismatchGroupCount > 0 {
            text += " · \(result.tagMismatchGroupCount) that tag matching would have missed"
        }
        if !result.failures.isEmpty {
            text += " · \(result.failures.count) could not be read"
        }
        return text + "."
    }

    private func summaryText(for result: FingerprintVerificationResult) -> String {
        var parts: [String] = []
        parts.append("Checked \(result.fingerprintedFileCount) file\(result.fingerprintedFileCount == 1 ? "" : "s")")

        if result.falsePositiveTrackCount > 0 {
            parts.append("ruled out \(result.falsePositiveTrackCount) track\(result.falsePositiveTrackCount == 1 ? "" : "s") that only shared tags")
        } else {
            parts.append("every group matched by audio")
        }

        if !result.failures.isEmpty {
            parts.append("\(result.failures.count) could not be read")
        }

        return parts.joined(separator: " · ") + "."
    }

    // MARK: - Auditioning

    private func isAuditioning(_ track: Track) -> Bool {
        auditioningPath == track.seratoStoredPath
    }

    /// Plays a copy, or pauses it if it's already the one playing.
    ///
    /// Switching to a different copy carries the playhead across, so two
    /// copies can be compared at the same moment in the music — the point of
    /// auditioning duplicates at all.
    private func toggleAudition(of track: Track, in group: DuplicateTrackGroup) {
        if isAuditioning(track) {
            auditionPlayer.togglePlayPause()
            return
        }

        let carriedPosition = auditioningGroupID == group.id ? auditionPlayer.currentTime : 0
        auditioningPath = track.seratoStoredPath
        auditioningGroupID = group.id
        auditionPlayer.audition(track: track, startingAt: carriedPosition)

        if auditionPlayer.errorMessage != nil {
            // Nothing is playing, so don't leave the row showing as active.
            auditioningPath = nil
            auditioningGroupID = nil
        }
    }

    private func stopAudition() {
        auditionPlayer.stopPlayback()
        auditioningPath = nil
        auditioningGroupID = nil
    }

    /// Stops playback if the loaded copy is no longer on screen — after a
    /// delete, a rescan, or an ignore.
    private func stopAuditionIfTrackVanished() {
        guard let auditioningPath else { return }
        let stillVisible = visibleGroups.contains { group in
            group.tracks.contains { $0.seratoStoredPath == auditioningPath }
        }
        if !stillVisible {
            stopAudition()
        }
    }

    private func auditionTransport(for group: DuplicateTrackGroup) -> some View {
        HStack(spacing: 8) {
            Button {
                auditionPlayer.togglePlayPause()
            } label: {
                Image(systemName: auditionPlayer.isPlaying ? "pause.fill" : "play.fill")
            }
            .controlSize(.small)
            .help(auditionPlayer.isPlaying ? "Pause" : "Play")

            Button {
                auditionPlayer.skip(by: -10)
            } label: {
                Image(systemName: "gobackward.10")
            }
            .controlSize(.small)
            .help("Back 10 seconds")

            Slider(
                value: Binding(
                    get: { auditionPlayer.currentTime },
                    set: { auditionPlayer.seek(to: $0) }
                ),
                in: 0...max(auditionPlayer.duration, 0.01)
            )
            .controlSize(.small)

            Text("\(timeLabel(auditionPlayer.currentTime)) / \(timeLabel(auditionPlayer.duration))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)

            Button {
                stopAudition()
            } label: {
                Image(systemName: "stop.fill")
            }
            .controlSize(.small)
            .help("Stop auditioning")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.accentColor.opacity(0.08)))
    }

    private func timeLabel(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    private func keptPath(for group: DuplicateTrackGroup) -> String? {
        let selected = keepSelectionByGroupID[group.id] ?? bestPathByGroupID[group.id]
        if let selected, group.tracks.contains(where: { $0.seratoStoredPath == selected }) {
            return selected
        }
        // The selected/best copy was ignored or removed from this group; fall
        // back to the best of the copies that are still present.
        return DuplicateTracksService.bestTrack(in: group.tracks)?.seratoStoredPath
    }

    private func deletableTracks(for group: DuplicateTrackGroup) -> [Track] {
        let kept = keptPath(for: group)
        return group.tracks.filter { $0.seratoStoredPath != kept }
    }

    private func pickBestForAll() {
        for group in filteredGroups {
            if let bestPath = bestPathByGroupID[group.id] {
                keepSelectionByGroupID[group.id] = bestPath
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
                fromComputer: fromComputer,
                keptPathByDeletedPath: keptPathMapping(for: group, deleting: tracks)
            )
        )
    }

    private func requestMassDeletion(fromComputer: Bool) {
        let tracks = filteredGroups.flatMap { deletableTracks(for: $0) }
        guard !tracks.isEmpty else { return }

        var mapping: [String: String] = [:]
        for group in filteredGroups {
            mapping.merge(keptPathMapping(for: group, deleting: deletableTracks(for: group))) { current, _ in current }
        }

        confirmOrPerform(
            PendingDeletion(
                groupLabel: "\(filteredGroups.count) groups",
                keepLabel: "the best copy in each group",
                tracks: tracks,
                fromComputer: fromComputer,
                keptPathByDeletedPath: mapping
            )
        )
    }

    /// Maps each copy being deleted to the copy that replaces it, so crates
    /// keep playing the same music afterward.
    private func keptPathMapping(for group: DuplicateTrackGroup, deleting tracks: [Track]) -> [String: String] {
        guard let kept = keptPath(for: group) else { return [:] }
        return Dictionary(uniqueKeysWithValues: tracks.map { ($0.seratoStoredPath, kept) })
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

        // Release the audio file before anything gets trashed — the player
        // holds an open handle on whatever it loaded.
        stopAudition()

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

            let cratePlan = try removeFromLibraryMetadata(
                paths: deletePaths,
                keptPathByDeletedPath: pending.keptPathByDeletedPath
            )
            onLibraryChanged()
            rebuildDuplicateGroups()

            let count = pending.tracks.count
            var message = pending.fromComputer
                ? "Moved \(trashedCount) file\(trashedCount == 1 ? "" : "s") to Trash and removed \(count) duplicate\(count == 1 ? "" : "s") from the library."
                : "Removed \(count) duplicate\(count == 1 ? "" : "s") from the library."
            if let crateSummary = CrateReconciliationService.summary(for: cratePlan) {
                message += " \(crateSummary)"
            }
            successMessage = message
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    @discardableResult
    private func removeFromLibraryMetadata(
        paths: Set<String>,
        keptPathByDeletedPath: [String: String]
    ) throws -> CrateReconciliationPlan {
        guard !paths.isEmpty else {
            return CrateReconciliationPlan(changes: [:], emptiedCrateNames: [])
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

        // Crates get the surviving copy in the deleted copy's slot. Simply
        // dropping the path would shorten every crate that referenced the
        // deleted copy but not the kept one.
        let plan = CrateReconciliationService.plan(
            crates: libraryService.crates,
            deletedPaths: paths,
            keptPathForDeleted: keptPathByDeletedPath
        )
        try CrateReconciliationService.apply(plan, to: libraryService.crates)
        return plan
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