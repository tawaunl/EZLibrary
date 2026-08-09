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
import EZLibraryCore

/// A library-wide track list shown beside the crate tree, so tracks can be
/// found and dragged straight into a crate.
///
/// Deliberately thin: `TrackTableView` already brings the search field, the
/// cached search index, sorting, and multi-row drag, and `CrateTreeView`
/// already accepts the drop. This just points the one at the other.
struct AllTracksBrowserView: View {
    enum Source: Equatable {
        case allTracks
        case notInCrates

        var title: String {
            switch self {
            case .allTracks: return "All Tracks"
            case .notInCrates: return "Not In Crates"
            }
        }

        var emptyMessage: String {
            switch self {
            case .allTracks:
                return "This library has no tracks yet."
            case .notInCrates:
                return "Every track is filed in at least one crate."
            }
        }
    }

    let source: Source
    let onTrackActivated: ((Track, [Track]) -> Void)?
    /// Called after a track is filed into a crate, so the library reloads and
    /// the counts and Not In Crates list catch up.
    let onCratesChanged: () -> Void

    @EnvironmentObject private var libraryService: LibraryService

    /// Built once per crate change rather than per body evaluation — it maps
    /// and sorts every crate in the library.
    @State private var crateTargets: [TrackContextMenuActions.CrateTarget] = []
    @State private var errorMessage: String?

    /// Filtering the library against every crate's contents is O(n); held here
    /// and refreshed only when the library changes rather than recomputed on
    /// each body evaluation.
    @State private var tracks: [Track] = []

    /// Lets the table cache its search index and rebuild it only when the
    /// underlying list actually changes.
    @State private var tableTracksVersion = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(source.title)
                    .font(.headline)
                Text("\(tracks.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                if !tracks.isEmpty {
                    Label("Drag onto a crate to add", systemImage: "arrow.left")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("Select one or more tracks and drag them onto a crate in the tree on the left.")
                }
            }

            if tracks.isEmpty {
                Text(source.emptyMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            } else {
                TrackTableView(
                    tracks: tracks,
                    tracksVersion: tableTracksVersion,
                    numberingMode: .listOrder,
                    onTrackActivated: { track, list in
                        onTrackActivated?(track, list)
                    },
                    contextActions: TrackContextMenuActions(
                        addToCrateTargets: crateTargets,
                        onAddToCrate: { selected, target in
                            addToCrate(selected, target: target)
                        }
                    )
                )
            }
        }
        .onAppear { refresh() }
        .onChange(of: source) { refresh() }
        .onChange(of: libraryService.revision) { refresh() }
        .onChange(of: libraryService.cratesRevision) { refresh() }
        .alert(
            "Couldn't Add to Crate",
            isPresented: Binding(
                get: { errorMessage != nil },
                set: { if !$0 { errorMessage = nil } })
        ) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private func refresh() {
        switch source {
        case .allTracks:
            tracks = libraryService.tracks
        case .notInCrates:
            tracks = UnfiledTracksService.tracksNotInAnyCrate(
                libraryService.tracks, crates: libraryService.crates)
        }
        crateTargets = CrateContextMenuSupport.targets(for: libraryService.crates)
        tableTracksVersion &+= 1
    }

    private func addToCrate(_ selected: [Track], target: TrackContextMenuActions.CrateTarget) {
        guard let crate = CrateContextMenuSupport.crate(
            withID: target.id, in: libraryService.crates) else { return }

        do {
            let change = try CrateMembershipService.add(
                storedPaths: selected.map(\.seratoStoredPath), to: crate)
            // Nothing moved when every track was already filed there, and a
            // reload would just churn the table for no visible change.
            guard change.didChange else { return }
            onCratesChanged()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
