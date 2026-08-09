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

struct UnfiledTracksServiceTests {

    private func track(_ path: String) -> Track {
        Track(
            seratoStoredPath: path,
            fileURL: URL(fileURLWithPath: "/\(path)"),
            title: (path as NSString).lastPathComponent
        )
    }

    private func crate(_ name: String, _ paths: [String]) -> Crate {
        Crate(pathComponents: [name], trackPaths: paths)
    }

    // MARK: - Basics

    @Test func returnsOnlyTracksNoCrateLists() {
        let tracks = [track("Music/a.mp3"), track("Music/b.mp3"), track("Music/c.mp3")]
        let crates = [crate("Bangers", ["Music/a.mp3"]), crate("House", ["Music/c.mp3"])]

        let unfiled = UnfiledTracksService.tracksNotInAnyCrate(tracks, crates: crates)

        #expect(unfiled.map(\.seratoStoredPath) == ["Music/b.mp3"])
    }

    @Test func everyTrackIsUnfiledWhenThereAreNoCrates() {
        let tracks = [track("Music/a.mp3"), track("Music/b.mp3")]

        #expect(UnfiledTracksService.tracksNotInAnyCrate(tracks, crates: []).count == 2)
    }

    @Test func nothingIsUnfiledWhenEveryTrackIsFiled() {
        let tracks = [track("Music/a.mp3"), track("Music/b.mp3")]
        let crates = [crate("All", ["Music/a.mp3", "Music/b.mp3"])]

        #expect(UnfiledTracksService.tracksNotInAnyCrate(tracks, crates: crates).isEmpty)
    }

    @Test func preservesLibraryOrder() {
        let tracks = [track("Music/c.mp3"), track("Music/a.mp3"), track("Music/b.mp3")]
        let crates = [crate("One", ["Music/a.mp3"])]

        let unfiled = UnfiledTracksService.tracksNotInAnyCrate(tracks, crates: crates)

        #expect(unfiled.map(\.seratoStoredPath) == ["Music/c.mp3", "Music/b.mp3"])
    }

    // MARK: - Path matching
    //
    // A track wrongly reported as unfiled sends the user off to re-file
    // something already filed, so the matching has to tolerate the ways a
    // crate entry and a database entry describe the same file differently.

    @Test func matchesDespiteCaseDifferences() {
        let tracks = [track("Music/Artist - Song.mp3")]
        let crates = [crate("One", ["music/artist - song.mp3"])]

        #expect(UnfiledTracksService.tracksNotInAnyCrate(tracks, crates: crates).isEmpty)
    }

    @Test func matchesDespiteALeadingSlash() {
        let tracks = [track("Music/a.mp3")]
        let crates = [crate("One", ["/Music/a.mp3"])]

        #expect(UnfiledTracksService.tracksNotInAnyCrate(tracks, crates: crates).isEmpty)
    }

    @Test func matchesDespiteBackslashSeparators() {
        let tracks = [track("Music/Sub/a.mp3")]
        let crates = [crate("One", ["Music\\Sub\\a.mp3"])]

        #expect(UnfiledTracksService.tracksNotInAnyCrate(tracks, crates: crates).isEmpty)
    }

    @Test func doesNotMatchADifferentTrackWithTheSameFileName() {
        let tracks = [track("Music/A/song.mp3"), track("Music/B/song.mp3")]
        let crates = [crate("One", ["Music/A/song.mp3"])]

        let unfiled = UnfiledTracksService.tracksNotInAnyCrate(tracks, crates: crates)

        #expect(unfiled.map(\.seratoStoredPath) == ["Music/B/song.mp3"])
    }

    // MARK: - Smart crates

    /// Smart-crate membership is rule-derived, so it doesn't count as filing.
    /// This also keeps the number consistent with the Tracks In Crates stat.
    @Test func smartCratesAreExcludedByDefault() {
        let tracks = [track("Music/a.mp3")]
        let smart = [crate("Recent", ["Music/a.mp3"])]

        let unfiled = UnfiledTracksService.tracksNotInAnyCrate(tracks, crates: [], smartCrates: [])

        #expect(unfiled.count == 1)
        // Passing them in explicitly is still supported.
        #expect(UnfiledTracksService.tracksNotInAnyCrate(
            tracks, crates: [], smartCrates: smart).isEmpty)
    }

    // MARK: - Count

    @Test func countAgreesWithTheList() {
        let tracks = (0..<20).map { track("Music/\($0).mp3") }
        let crates = [crate("One", (0..<7).map { "Music/\($0).mp3" })]

        let count = UnfiledTracksService.countOfTracksNotInAnyCrate(tracks, crates: crates)
        let list = UnfiledTracksService.tracksNotInAnyCrate(tracks, crates: crates)

        #expect(count == 13)
        #expect(count == list.count)
    }

    @Test func countIsEveryTrackWhenNoCratesExist() {
        let tracks = (0..<5).map { track("Music/\($0).mp3") }

        #expect(UnfiledTracksService.countOfTracksNotInAnyCrate(tracks, crates: []) == 5)
    }

    @Test func handlesAnEmptyLibrary() {
        #expect(UnfiledTracksService.tracksNotInAnyCrate([], crates: []).isEmpty)
        #expect(UnfiledTracksService.countOfTracksNotInAnyCrate([], crates: []) == 0)
    }

    /// A crate can list a path with no matching track (a missing file). That
    /// must not affect which tracks are reported as unfiled.
    @Test func crateEntriesWithNoMatchingTrackAreHarmless() {
        let tracks = [track("Music/a.mp3")]
        let crates = [crate("One", ["Music/gone.mp3", "Music/also-gone.mp3"])]

        #expect(UnfiledTracksService.tracksNotInAnyCrate(tracks, crates: crates).count == 1)
    }
}
