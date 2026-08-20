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

private func track(_ storedPath: String, title: String = "Midnight Drive", artist: String = "Nova") -> Track {
    Track(
        seratoStoredPath: storedPath,
        fileURL: URL(fileURLWithPath: "/" + storedPath),
        title: title,
        artist: artist
    )
}

private func reference(_ storedPath: String, title: String = "Midnight Drive", artist: String = "Nova") -> TrackReference {
    TrackReference(storedPath: storedPath, title: title, artist: artist)
}

@Test func resolverPrefersAnExactPathMatch() {
    let resolver = TrackIdentityResolver(currentTracks: [track("Music/All Music/Midnight Drive.mp3")])
    #expect(
        resolver.resolve(reference("Music/All Music/Midnight Drive.mp3"))
            == .resolved(storedPath: "Music/All Music/Midnight Drive.mp3", via: .exactPath)
    )
}

/// The case the whole journal exists for: consolidation moved the file and
/// recorded where it went, so this is a lookup rather than a guess.
@Test func resolverUsesTheJournalForAMoveEZLibraryMade() {
    var journal = LibraryChangeJournal()
    journal.record(.trackMoved(from: "Music/All Music/Track.mp3", to: "Music/Consolidated/Renamed.mp3"))
    let resolver = TrackIdentityResolver(
        currentTracks: [track("Music/Consolidated/Renamed.mp3")],
        journal: journal
    )
    #expect(
        resolver.resolve(reference("Music/All Music/Track.mp3"))
            == .resolved(storedPath: "Music/Consolidated/Renamed.mp3", via: .journal)
    )
}

/// A journal entry pointing at a file that is no longer in the library must
/// not win — it has to fall through to the approximate rungs.
@Test func resolverIgnoresAJournalDestinationThatIsGone() {
    var journal = LibraryChangeJournal()
    journal.record(.trackMoved(from: "old/Track.mp3", to: "deleted/Track.mp3"))
    let resolver = TrackIdentityResolver(
        currentTracks: [track("elsewhere/Track.mp3")],
        journal: journal
    )
    #expect(
        resolver.resolve(reference("old/Track.mp3"))
            == .resolved(storedPath: "elsewhere/Track.mp3", via: .basename)
    )
}

@Test func resolverFallsBackToBasenameWhenAFolderChanged() {
    let resolver = TrackIdentityResolver(currentTracks: [track("Music/Consolidated/Midnight Drive.mp3")])
    #expect(
        resolver.resolve(reference("Music/All Music/Midnight Drive.mp3"))
            == .resolved(storedPath: "Music/Consolidated/Midnight Drive.mp3", via: .basename)
    )
}

@Test func resolverMatchesBasenamesCaseInsensitively() {
    let resolver = TrackIdentityResolver(currentTracks: [track("Music/Consolidated/MIDNIGHT DRIVE.MP3")])
    #expect(
        resolver.resolve(reference("Music/All Music/Midnight Drive.mp3"))
            == .resolved(storedPath: "Music/Consolidated/MIDNIGHT DRIVE.MP3", via: .basename)
    )
}

/// Colliding filenames are the reason the basename rung has to corroborate:
/// "01 - Intro.mp3" is not a unique key in a real library.
@Test func collidingBasenamesAreSettledByTitleAndArtist() {
    let resolver = TrackIdentityResolver(currentTracks: [
        track("Music/AlbumA/01 - Intro.mp3", title: "Intro", artist: "Nova"),
        track("Music/AlbumB/01 - Intro.mp3", title: "Intro", artist: "Other Band")
    ])
    #expect(
        resolver.resolve(reference("Music/Old/01 - Intro.mp3", title: "Intro", artist: "Other Band"))
            == .resolved(storedPath: "Music/AlbumB/01 - Intro.mp3", via: .basename)
    )
}

@Test func collidingBasenamesWithNoCorroborationAreAmbiguous() {
    let resolver = TrackIdentityResolver(currentTracks: [
        track("Music/AlbumA/01 - Intro.mp3", title: "Intro", artist: "Nova"),
        track("Music/AlbumB/01 - Intro.mp3", title: "Intro", artist: "Nova")
    ])
    #expect(
        resolver.resolve(reference("Music/Old/01 - Intro.mp3", title: "Intro", artist: "Nova"))
            == .ambiguous(
                candidates: ["Music/AlbumA/01 - Intro.mp3", "Music/AlbumB/01 - Intro.mp3"],
                via: .basename
            )
    )
}

/// Renamed *and* moved by something outside EZLibrary — the last rung before
/// giving up.
@Test func resolverFallsBackToTitleAndArtist() {
    let resolver = TrackIdentityResolver(currentTracks: [
        track("Music/Consolidated/Nova - Midnight Drive (2026 Remaster).mp3")
    ])
    #expect(
        resolver.resolve(reference("Music/All Music/midnight.mp3"))
            == .resolved(
                storedPath: "Music/Consolidated/Nova - Midnight Drive (2026 Remaster).mp3",
                via: .titleArtist
            )
    )
}

@Test func titleAndArtistMatchingIgnoresCaseAndSurroundingWhitespace() {
    let resolver = TrackIdentityResolver(currentTracks: [
        track("Music/x.mp3", title: "  Midnight Drive ", artist: "NOVA")
    ])
    #expect(
        resolver.resolve(reference("Music/gone.mp3", title: "midnight drive", artist: "nova"))
            == .resolved(storedPath: "Music/x.mp3", via: .titleArtist)
    )
}

@Test func aTrackThatIsSimplyGoneIsUnresolved() {
    let resolver = TrackIdentityResolver(currentTracks: [track("Music/Something Else.mp3", title: "Other", artist: "Band")])
    #expect(resolver.resolve(reference("Music/Deleted.mp3")) == .unresolved)
}

/// An untitled, unattributed track must not collide with every other one, so
/// the title/artist rung declines to answer rather than matching broadly.
@Test func untitledTracksDoNotMatchOnEmptyMetadata() {
    let resolver = TrackIdentityResolver(currentTracks: [track("Music/a.mp3", title: "", artist: "")])
    #expect(resolver.resolve(reference("Music/b.mp3", title: "", artist: "")) == .unresolved)
}

@Test func duplicateTitleAndArtistAcrossTwoFilesIsAmbiguous() {
    let resolver = TrackIdentityResolver(currentTracks: [
        track("Music/copy1.mp3"),
        track("Music/copy2.mp3")
    ])
    #expect(
        resolver.resolve(reference("Music/original.mp3"))
            == .ambiguous(candidates: ["Music/copy1.mp3", "Music/copy2.mp3"], via: .titleArtist)
    )
}
