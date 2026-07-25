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
import Testing
@testable import EZLibraryCore

private func track(_ path: String) -> Track {
    Track(
        seratoStoredPath: path,
        fileURL: URL(fileURLWithPath: "/tmp/\(path)"),
        title: "Anthem",
        artist: "Artist"
    )
}

private func group(_ id: String, _ paths: [String], version: String = "Original") -> DuplicateTrackGroup {
    DuplicateTrackGroup(
        id: id,
        artist: "Artist",
        title: "Anthem",
        versionLabel: version,
        tracks: paths.map(track)
    )
}

@Test func deletedCopyIsRemovedButTheGroupSurvives() {
    let groups = [group("g1", ["a.mp3", "b.mp3", "c.mp3"])]

    let pruned = DuplicateTracksService.removingTracks(from: groups) {
        $0.seratoStoredPath == "b.mp3"
    }

    #expect(pruned.count == 1)
    #expect(pruned[0].tracks.map(\.seratoStoredPath) == ["a.mp3", "c.mp3"])
    #expect(pruned[0].id == "g1")
}

@Test func groupFallingBelowTwoCopiesIsDropped() {
    // One copy left is no longer a duplicate.
    let groups = [group("g1", ["a.mp3", "b.mp3"])]

    let pruned = DuplicateTracksService.removingTracks(from: groups) {
        $0.seratoStoredPath == "b.mp3"
    }

    #expect(pruned.isEmpty)
}

@Test func untouchedGroupsKeepTheirIdentity() {
    // Identity matters: audio verdicts, version siblings and keep selections
    // are all keyed by group id, and must survive a delete elsewhere.
    let groups = [
        group("g1", ["a.mp3", "b.mp3"]),
        group("g2", ["x.mp3", "y.mp3"], version: "Quick Hit · Dirty")
    ]

    let pruned = DuplicateTracksService.removingTracks(from: groups) {
        $0.seratoStoredPath == "a.mp3"
    }

    #expect(pruned.map(\.id) == ["g2"])
    #expect(pruned[0].versionLabel == "Quick Hit · Dirty")
    #expect(pruned[0].tracks.count == 2)
}

@Test func removingNothingReturnsEverythingUnchanged() {
    let groups = [group("g1", ["a.mp3", "b.mp3"]), group("g2", ["x.mp3", "y.mp3"])]

    let pruned = DuplicateTracksService.removingTracks(from: groups) { _ in false }

    #expect(pruned.count == 2)
    #expect(pruned.map(\.id) == ["g1", "g2"])
    #expect(pruned.map(\.trackCount) == [2, 2])
}

@Test func aDeleteAcrossSeveralGroupsPrunesEachIndependently() {
    let groups = [
        group("g1", ["a.mp3", "b.mp3", "c.mp3"]),
        group("g2", ["x.mp3", "y.mp3"]),
        group("g3", ["p.mp3", "q.mp3", "r.mp3"])
    ]
    let deleted: Set<String> = ["b.mp3", "y.mp3", "q.mp3"]

    let pruned = DuplicateTracksService.removingTracks(from: groups) {
        deleted.contains($0.seratoStoredPath)
    }

    // g2 drops to one copy and disappears; the others shrink but stay.
    #expect(pruned.map(\.id) == ["g1", "g3"])
    #expect(pruned.map(\.trackCount) == [2, 2])
}

@Test func removingEverythingLeavesNoGroups() {
    let groups = [group("g1", ["a.mp3", "b.mp3"]), group("g2", ["x.mp3", "y.mp3"])]
    #expect(DuplicateTracksService.removingTracks(from: groups) { _ in true }.isEmpty)
}

@Test func pruningEmptyResultsIsSafe() {
    #expect(DuplicateTracksService.removingTracks(from: []) { _ in true }.isEmpty)
}

@Test func summaryReflectsPrunedGroupsWithoutARescan() {
    let groups = [group("g1", ["a.mp3", "b.mp3", "c.mp3"]), group("g2", ["x.mp3", "y.mp3"])]

    let pruned = DuplicateTracksService.removingTracks(from: groups) {
        $0.seratoStoredPath == "y.mp3"
    }
    let summary = DuplicateTracksService.summary(forGroups: pruned, totalTracks: 100)

    #expect(summary.duplicateGroupCount == 1)
    #expect(summary.redundantTrackCount == 2)
    #expect(summary.totalTracks == 100)
}
