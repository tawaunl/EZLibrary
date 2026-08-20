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
import EZLibrarySnapshotKit

/// What the track list is currently showing.
enum LibraryScope: Hashable {
    case allTracks
    case notInCrates
    case crate(SnapshotCrateNode)

    var title: String {
        switch self {
        case .allTracks: return "All Tracks"
        case .notInCrates: return "Not in Crates"
        case let .crate(node): return node.name
        }
    }
}

struct LibraryBrowser: View {
    let library: SnapshotLibrary
    let chooseFolder: () -> Void

    @Environment(SnapshotStore.self) private var store

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink(value: LibraryScope.allTracks) {
                        Label("All Tracks", systemImage: "music.note.list")
                            .badge(library.trackCount)
                    }
                    NavigationLink(value: LibraryScope.notInCrates) {
                        Label("Not in Crates", systemImage: "tray")
                            .badge(library.tracksNotInAnyCrate.count)
                    }
                }

                Section("Crates") {
                    ForEach(library.crateTree) { node in
                        CrateRow(node: node, library: library)
                    }
                }

                Section {
                    // Offline data is only as good as the reader's sense of how
                    // old it is, so the export time is shown, not hidden in a
                    // settings screen.
                    LabeledContent("Snapshot taken", value: library.generatedAt.formatted(.relative(presentation: .named)))
                        .font(.footnote)
                    Button("Check for a Newer Snapshot") { store.reload() }
                        .font(.footnote)
                    Button("Choose Another Folder", action: chooseFolder)
                        .font(.footnote)
                }
            }
            .navigationTitle("Library")
            .navigationDestination(for: LibraryScope.self) { scope in
                TrackListView(library: library, scope: scope)
            }
            .navigationDestination(for: SnapshotTrack.self) { track in
                TrackDetailView(track: track)
            }
            .refreshable { store.reload() }
        }
    }
}

/// One crate in the sidebar. Nested crates expand in place; a crate with
/// children is still tappable, because a parent crate can hold tracks of its
/// own as well as children.
private struct CrateRow: View {
    let node: SnapshotCrateNode
    let library: SnapshotLibrary

    var body: some View {
        if node.children.isEmpty {
            NavigationLink(value: LibraryScope.crate(node)) {
                Label(node.name, systemImage: "square.stack")
                    .badge(node.trackPaths.count)
            }
        } else {
            DisclosureGroup {
                NavigationLink(value: LibraryScope.crate(node)) {
                    Label("Everything in \(node.name)", systemImage: "square.stack.3d.up")
                        .badge(node.allTrackPaths.count)
                }
                ForEach(node.children) { child in
                    CrateRow(node: child, library: library)
                }
            } label: {
                Label(node.name, systemImage: "folder")
            }
        }
    }
}
