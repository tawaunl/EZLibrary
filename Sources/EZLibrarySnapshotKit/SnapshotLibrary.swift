// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Foundation

/// A loaded snapshot, prepared for browsing.
///
/// Everything the UI needs repeatedly — the crate tree, the path-to-track
/// index, the lowercased search blobs — is built once here rather than on
/// every keystroke or every row. A 2,362-track library rebuilding its search
/// bytes per keystroke is exactly how a phone list gets janky.
public struct SnapshotLibrary: Sendable {
    public let snapshot: LibrarySnapshot

    /// The nested crate tree, ordered as the Mac orders it.
    public let crateTree: [SnapshotCrateNode]

    private let tracksByPath: [String: SnapshotTrack]

    /// Tracks in snapshot order, paired with their prebuilt search bytes.
    private let searchIndex: [(track: SnapshotTrack, bytes: [UInt8])]

    public init(snapshot: LibrarySnapshot, includeFileNameInSearch: Bool = true) {
        self.snapshot = snapshot
        self.crateTree = SnapshotCrateTree.build(from: snapshot.crates)
        self.tracksByPath = Dictionary(
            snapshot.tracks.map { ($0.storedPath, $0) },
            // A library shouldn't contain the same stored path twice, but a
            // hand-edited snapshot could. Keep the first rather than trapping.
            uniquingKeysWith: { first, _ in first }
        )
        self.searchIndex = snapshot.tracks.map { track in
            (track, SnapshotTrackSearch.searchBytes(for: track, includeFileName: includeFileNameInSearch))
        }
    }

    // MARK: - Browsing

    public var allTracks: [SnapshotTrack] { snapshot.tracks }
    public var trackCount: Int { snapshot.tracks.count }
    public var crateCount: Int { snapshot.crates.count }
    public var generatedAt: Date { snapshot.generatedAt }

    public func track(for storedPath: String) -> SnapshotTrack? {
        tracksByPath[storedPath]
    }

    /// The tracks listed in one crate, in the order the crate lists them.
    ///
    /// A path with no matching track is skipped rather than substituted: it
    /// means the snapshot is internally inconsistent, and inventing a
    /// placeholder row would hide that.
    public func tracks(in crate: SnapshotCrate) -> [SnapshotTrack] {
        crate.trackPaths.compactMap { tracksByPath[$0] }
    }

    /// The tracks in a crate node and everything nested under it,
    /// deduplicated.
    public func tracks(in node: SnapshotCrateNode) -> [SnapshotTrack] {
        node.allTrackPaths.compactMap { tracksByPath[$0] }
    }

    /// Tracks that no crate lists — the phone-side equivalent of the Mac's
    /// "not in crates" view, and usually the first thing a DJ wants to tidy.
    public var tracksNotInAnyCrate: [SnapshotTrack] {
        var filed = Set<String>()
        for crate in snapshot.crates {
            filed.formUnion(crate.trackPaths)
        }
        return snapshot.tracks.filter { !filed.contains($0.storedPath) }
    }

    // MARK: - Search

    /// Case-insensitive search over the whole library, using the prebuilt
    /// byte blobs. An empty query returns everything, in snapshot order.
    public func search(_ query: String) -> [SnapshotTrack] {
        let needle = ByteTextSearch.needle(for: query)
        guard !needle.isEmpty else { return snapshot.tracks }
        return searchIndex.compactMap { entry in
            ByteTextSearch.matches(bytes: entry.bytes, needle: needle) ? entry.track : nil
        }
    }

    /// Search restricted to one crate subtree.
    public func search(_ query: String, in node: SnapshotCrateNode) -> [SnapshotTrack] {
        let scoped = tracks(in: node)
        let needle = ByteTextSearch.needle(for: query)
        guard !needle.isEmpty else { return scoped }
        return scoped.filter {
            ByteTextSearch.matches(
                bytes: SnapshotTrackSearch.searchBytes(for: $0, includeFileName: true),
                needle: needle
            )
        }
    }
}
