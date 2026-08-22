// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Testing
import Foundation
@testable import EZLibraryCore

private func snapshotTrack(
    _ path: String,
    title: String = "",
    artist: String = "",
    album: String = "",
    genre: String = ""
) -> SnapshotTrack {
    SnapshotTrack(storedPath: path, title: title, artist: artist, album: album, genre: genre)
}

// MARK: - Crate tree

@Test func crateTreeNestsChildrenUnderSynthesizedFolders() {
    let nodes = SnapshotCrateTree.build(from: [
        SnapshotCrate(pathComponents: ["ALL GENRES", "Disco"], trackPaths: ["a.mp3"]),
        SnapshotCrate(pathComponents: ["ALL GENRES", "House"], trackPaths: ["b.mp3"])
    ])

    #expect(nodes.count == 1)
    #expect(nodes[0].name == "ALL GENRES")
    // No crate of its own — it exists only because children reference it.
    #expect(nodes[0].crate == nil)
    #expect(nodes[0].children.map(\.name) == ["Disco", "House"])
}

@Test func crateTreeSortsSiblingsByName() {
    let nodes = SnapshotCrateTree.build(from: [
        SnapshotCrate(pathComponents: ["Zed"], trackPaths: []),
        SnapshotCrate(pathComponents: ["Alpha"], trackPaths: []),
        SnapshotCrate(pathComponents: ["Mid"], trackPaths: [])
    ])
    #expect(nodes.map(\.name) == ["Alpha", "Mid", "Zed"])
}

@Test func crateNodeIDIsStableAndDistinguishesSameNamedCrates() {
    let nodes = SnapshotCrateTree.build(from: [
        SnapshotCrate(pathComponents: ["2025", "Warmup"], trackPaths: []),
        SnapshotCrate(pathComponents: ["2026", "Warmup"], trackPaths: [])
    ])
    let ids = nodes.flatMap { $0.children.map(\.id) }
    #expect(ids == ["2025/Warmup", "2026/Warmup"])
}

@Test func allTrackPathsGathersTheWholeSubtree() {
    let nodes = SnapshotCrateTree.build(from: [
        SnapshotCrate(pathComponents: ["Sets"], trackPaths: ["intro.mp3"]),
        SnapshotCrate(pathComponents: ["Sets", "Peak"], trackPaths: ["banger.mp3"]),
        SnapshotCrate(pathComponents: ["Sets", "Close"], trackPaths: ["outro.mp3"])
    ])
    #expect(nodes[0].allTrackPaths == ["intro.mp3", "outro.mp3", "banger.mp3"])
}

/// A track filed in both a parent and its child must appear once, not twice.
@Test func allTrackPathsDeduplicatesAcrossNestedCrates() {
    let nodes = SnapshotCrateTree.build(from: [
        SnapshotCrate(pathComponents: ["Sets"], trackPaths: ["shared.mp3"]),
        SnapshotCrate(pathComponents: ["Sets", "Peak"], trackPaths: ["shared.mp3", "other.mp3"])
    ])
    #expect(nodes[0].allTrackPaths == ["shared.mp3", "other.mp3"])
}

@Test func emptyCratePathsAreIgnored() {
    #expect(SnapshotCrateTree.build(from: [SnapshotCrate(pathComponents: [], trackPaths: ["a"])]).isEmpty)
}

/// The phone and the Mac must nest and order crates identically.
@Test func snapshotCrateTreeMatchesTheMacCrateHierarchy() {
    let crates = [
        Crate(pathComponents: ["ALL GENRES", "Disco"], trackPaths: ["a.mp3"]),
        Crate(pathComponents: ["ALL GENRES", "House"], trackPaths: ["b.mp3"]),
        Crate(pathComponents: ["Sets"], trackPaths: ["c.mp3"])
    ]

    let macNodes = CrateHierarchy.build(from: crates)
    let snapshotNodes = SnapshotCrateTree.build(from: crates.map(SnapshotCrate.init(crate:)))

    #expect(macNodes.map(\.id) == snapshotNodes.map(\.id))
    #expect(macNodes.map { $0.children.map(\.id) } == snapshotNodes.map { $0.children.map(\.id) })
}

// MARK: - Search

@Test func snapshotSearchMatchesAcrossTheSameFieldsAsTheMac() {
    let tracks = [
        snapshotTrack("a.mp3", title: "Feel So Close", artist: "Calvin Harris", album: "18 Months", genre: "House"),
        snapshotTrack("b.mp3", title: "Titanium", artist: "David Guetta", album: "Nothing but the Beat", genre: "Pop")
    ]

    #expect(SnapshotTrackSearch.filter(tracks, query: "calvin").map(\.title) == ["Feel So Close"])
    #expect(SnapshotTrackSearch.filter(tracks, query: "GUETTA").map(\.title) == ["Titanium"])
    #expect(SnapshotTrackSearch.filter(tracks, query: "house").map(\.title) == ["Feel So Close"])
    #expect(SnapshotTrackSearch.filter(tracks, query: "months").map(\.title) == ["Feel So Close"])
}

@Test func snapshotSearchReturnsEverythingForABlankQuery() {
    let tracks = [snapshotTrack("a.mp3", title: "One"), snapshotTrack("b.mp3", title: "Two")]
    #expect(SnapshotTrackSearch.filter(tracks, query: "").count == 2)
    #expect(SnapshotTrackSearch.filter(tracks, query: "   ").count == 2)
}

/// The separator byte must stop a query matching across two fields.
@Test func snapshotSearchDoesNotMatchAcrossFieldBoundaries() {
    let tracks = [snapshotTrack("a.mp3", title: "Feel So Close", artist: "Calvin Harris")]
    #expect(SnapshotTrackSearch.filter(tracks, query: "closecalvin").isEmpty)
}

@Test func snapshotSearchCanIncludeTheFileName() {
    let track = snapshotTrack("Music/mystery-bootleg.mp3", title: "Untitled")
    #expect(SnapshotTrackSearch.filter([track], query: "mystery").isEmpty)
    #expect(SnapshotTrackSearch.filter([track], query: "mystery", includeFileName: true).count == 1)
}

/// Both sides run the same matcher, so the same library must give the same
/// hits whichever type it is expressed as.
@Test func snapshotSearchAgreesWithTheMacSearch() {
    let tracks = [
        Track(seratoStoredPath: "Music/a.mp3", fileURL: URL(fileURLWithPath: "/Music/a.mp3"),
              title: "Feel So Close", artist: "Calvin Harris", album: "18 Months", genre: "House"),
        Track(seratoStoredPath: "Music/b.mp3", fileURL: URL(fileURLWithPath: "/Music/b.mp3"),
              title: "Titanium", artist: "David Guetta", album: "Nothing but the Beat", genre: "Pop")
    ]
    let snapshotTracks = tracks.map(SnapshotTrack.init(track:))

    for query in ["calvin", "GUETTA", "house", "closecalvin", "beat", ""] {
        let macHits = TrackTextSearch.filter(tracks, query: query).map(\.seratoStoredPath)
        let phoneHits = SnapshotTrackSearch.filter(snapshotTracks, query: query).map(\.storedPath)
        #expect(macHits == phoneHits, "query \"\(query)\" disagreed")
    }
}
