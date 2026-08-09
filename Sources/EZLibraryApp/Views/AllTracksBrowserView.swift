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

/// The whole library, shown beside the crate tree so tracks can be found and
/// dragged straight into a crate.
///
/// Deliberately thin: `TrackTableView` already brings the search field, the
/// cached search index, sorting, and multi-row drag, and `CrateTreeView`
/// already accepts the drop. This just points the one at the other.
struct AllTracksBrowserView: View {
    let onTrackActivated: ((Track, [Track]) -> Void)?

    @EnvironmentObject private var libraryService: LibraryService

    /// Lets the table cache its search index and rebuild it only when the
    /// library actually changes, rather than on every update pass.
    @State private var tableTracksVersion = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("All Tracks")
                    .font(.headline)
                Text("\(libraryService.tracks.count) tracks")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                Spacer(minLength: 0)

                Label("Drag onto a crate to add", systemImage: "arrow.left")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .help("Select one or more tracks and drag them onto a crate in the tree on the left.")
            }

            TrackTableView(
                tracks: libraryService.tracks,
                tracksVersion: tableTracksVersion,
                numberingMode: .listOrder,
                onTrackActivated: { track, list in
                    onTrackActivated?(track, list)
                }
            )
        }
        .onAppear { tableTracksVersion &+= 1 }
        .onChange(of: libraryService.revision) { tableTracksVersion &+= 1 }
    }
}
