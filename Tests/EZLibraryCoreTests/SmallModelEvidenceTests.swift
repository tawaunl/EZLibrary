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

private func candidate(
    _ source: OnlineMetadataSource,
    album: String,
    artist: String = "Avicii",
    seconds: Double? = nil
) -> OnlineTrackMetadataCandidate {
    OnlineTrackMetadataCandidate(
        source: source, title: "Levels", artist: artist, album: album,
        genre: "House", year: 2011, bpm: nil, durationSeconds: seconds
    )
}

// MARK: - What gets dropped

@Test func compilationsSeenInALiveRunAreRecognised() {
    // Both proposed by the on-device model in a measured run.
    #expect(SmallModelEvidence.isCompilationLike(album: "Clubland 100% Euphoric", artist: "Avicii"))
    #expect(SmallModelEvidence.isCompilationLike(album: "Now That's What I Call Music! 80", artist: "Avicii"))
    #expect(SmallModelEvidence.isCompilationLike(album: "Summer 2012", artist: "Various Artists"))
    // Real albums with ordinary words in their titles stay.
    #expect(!SmallModelEvidence.isCompilationLike(album: "Random Access Memories", artist: "Daft Punk"))
    #expect(!SmallModelEvidence.isCompilationLike(album: "Sorry for Party Rocking", artist: "LMFAO"))
}

@Test func aRemixesEPIsWrongForTheOriginalButRightForARemix() {
    let ep = "Feel So Close (Remixes) - EP"
    #expect(SmallModelEvidence.isRemixRelease(album: ep, forTitle: "Feel So Close"))
    // "Original Mix" is the original, not a remix.
    #expect(SmallModelEvidence.isRemixRelease(album: ep, forTitle: "Feel So Close (Original Mix)"))
    #expect(!SmallModelEvidence.isRemixRelease(album: ep, forTitle: "Feel So Close (Nero Remix)"))
    #expect(!SmallModelEvidence.isRemixRelease(album: "18 Months", forTitle: "Feel So Close"))
}

@Test func compilationsAndRemixCollectionsAreLeftOutWhileARealAlbumRemains() {
    let curated = SmallModelEvidence.curated(
        [
            candidate(.itunes, album: "Clubland 100% Euphoric"),
            candidate(.deezer, album: "Levels (Remixes) - EP"),
            candidate(.itunes, album: "Levels - Single")
        ],
        fileTitle: "Levels (Original Mix)",
        fileDuration: nil
    )
    #expect(curated.map(\.album) == ["Levels - Single"])
}

@Test func aTrackOnlyEverOnACompilationStillKeepsItsResults() {
    let curated = SmallModelEvidence.curated(
        [candidate(.itunes, album: "Clubland 100% Euphoric")],
        fileTitle: "Levels",
        fileDuration: nil
    )
    #expect(curated.count == 1)
}

// MARK: - Order and size

@Test func wikipediaComesFirstThenTheClosestLength() {
    let curated = SmallModelEvidence.curated(
        [
            candidate(.itunes, album: "Far", seconds: 200),
            candidate(.deezer, album: "Close", seconds: 361),
            candidate(.wikipedia, album: "Original"),
            candidate(.itunes, album: "No length")
        ],
        fileTitle: "Levels",
        fileDuration: 362
    )
    #expect(curated.map(\.album) == ["Original", "Close", "Far", "No length"])
}

@Test func atMostSixResultsReachTheModel() {
    let many = (1...12).map { candidate(.itunes, album: "Album \($0)") }
    let curated = SmallModelEvidence.curated(many, fileTitle: "Levels", fileDuration: nil)
    #expect(curated.count == SmallModelEvidence.candidateLimit)
    // Without lengths to compare, the databases' own order is kept.
    #expect(curated.first?.album == "Album 1")
}

// MARK: - The prompt

#if canImport(FoundationModels)
private func emptyTagsTrack() -> Track {
    Track(
        seratoStoredPath: "Music/Avicii - Levels.mp3",
        fileURL: URL(fileURLWithPath: "/nonexistent/Avicii - Levels.mp3"),
        title: "Levels", artist: "Avicii", album: "", genre: "", comment: "", year: nil
    )
}

@available(macOS 26.0, *)
@Test func thePromptNamesEveryEmptyFieldToFill() {
    let prompt = OnDeviceTagVerificationService.prompt(
        for: emptyTagsTrack(),
        fileTags: AudioFileTagReader.Tags(title: nil, artist: nil),
        candidates: [candidate(.itunes, album: "True")]
    )
    #expect(prompt.contains("EMPTY FIELDS TO FILL: album, genre, year."))
    // Given results, the model is not told to search.
    #expect(!prompt.contains("search_music_databases"))
}

@available(macOS 26.0, *)
@Test func aFullyTaggedTrackHasNoEmptyFieldLine() {
    let full = Track(
        seratoStoredPath: "Music/a.mp3", fileURL: URL(fileURLWithPath: "/nonexistent/a.mp3"),
        title: "Levels", artist: "Avicii", album: "True", genre: "House", comment: "", year: 2011
    )
    let prompt = OnDeviceTagVerificationService.prompt(for: full, fileTags: AudioFileTagReader.Tags(title: nil, artist: nil))
    #expect(!prompt.contains("EMPTY FIELDS"))
}

@available(macOS 26.0, *)
@Test func theInstructionsOnlyMentionTheSearchToolWhenItIsOffered() {
    let without = OnDeviceTagVerificationService.instructions(searchAvailable: false)
    let with = OnDeviceTagVerificationService.instructions(searchAvailable: true)
    #expect(without.contains("there is no search tool"))
    #expect(!without.contains("Call search_music_databases"))
    #expect(with.contains("Call search_music_databases once"))
    // Both carry the goal and the shared rules.
    for text in [without, with] {
        #expect(text.contains("all five fields filled"))
        #expect(text.contains("2. Pick the matching version."))
        #expect(text.contains("Keep version wording."))
    }
}
#endif

// MARK: - Singles, EPs, and remix singles

@Test func aSingleNamedAfterARemixIsDroppedForTheOriginal() {
    // Proposed by the on-device model for the original "Midnight City".
    let album = "Midnight City (Eric Prydz Private Remix) - Single"
    #expect(SmallModelEvidence.isRemixRelease(album: album, forTitle: "Midnight City"))
    #expect(!SmallModelEvidence.isRemixRelease(album: album, forTitle: "Midnight City (Eric Prydz Private Remix)"))
}

@Test func singlesAndEPsAreRecognisedButAlbumsAreNot() {
    #expect(SmallModelEvidence.isSingleOrEP(album: "One More Time - Single"))
    #expect(SmallModelEvidence.isSingleOrEP(album: "Levels - EP"))
    #expect(SmallModelEvidence.isSingleOrEP(album: "Midnight City EP"))
    #expect(!SmallModelEvidence.isSingleOrEP(album: "Discovery"))
    // "Deep" ends in "ep" but is not an EP.
    #expect(!SmallModelEvidence.isSingleOrEP(album: "Deep"))
    #expect(!SmallModelEvidence.isSingleOrEP(album: "Singles"))
}

@Test func albumsRankAheadOfSinglesAndEPsButBehindWikipedia() {
    let curated = SmallModelEvidence.curated(
        [
            candidate(.itunes, album: "Digital Love - Single", seconds: 320),
            candidate(.deezer, album: "Discovery", seconds: 200),
            candidate(.wikipedia, album: "Discovery")
        ],
        fileTitle: "One More Time",
        fileDuration: 320
    )
    // The album wins even though the single's length is the exact match. (A
    // single named after the song itself would be hidden outright here.)
    #expect(curated.map(\.album) == ["Discovery", "Discovery", "Digital Love - Single"])
    #expect(curated.first?.source == .wikipedia)
}

@Test func aTrackOnlyReleasedAsASingleKeepsIt() {
    let curated = SmallModelEvidence.curated(
        [candidate(.itunes, album: "Levels - Single")],
        fileTitle: "Levels",
        fileDuration: nil
    )
    #expect(curated.map(\.album) == ["Levels - Single"])
}

// MARK: - Lead singles hidden only when an album replaces them

private func release(_ source: OnlineMetadataSource, _ album: String, title: String = "Midnight City", artist: String = "M83") -> OnlineTrackMetadataCandidate {
    OnlineTrackMetadataCandidate(source: source, title: title, artist: artist, album: album, genre: "", year: 2011, bpm: nil)
}

@Test func aLeadSingleEPIsHiddenWhenWikipediaNamesTheAlbum() {
    // The real Midnight City results: the model picked the EP even ranked below.
    let curated = SmallModelEvidence.curated(
        [
            release(.itunes, "Hurry Up, We're Dreaming"),
            release(.itunes, "Midnight City - EP"),
            release(.deezer, "Midnight City"),
            release(.wikipedia, "Hurry Up, We're Dreaming")
        ],
        fileTitle: "Midnight City",
        fileDuration: nil
    )
    #expect(curated.map(\.album) == ["Hurry Up, We're Dreaming", "Hurry Up, We're Dreaming"])
}

@Test func twoDatabasesAgreeingAlsoConfirmTheAlbum() {
    let curated = SmallModelEvidence.curated(
        [release(.itunes, "Discovery"), release(.deezer, "Discovery"), release(.itunes, "One More Time - Single")],
        fileTitle: "One More Time", fileDuration: nil
    )
    #expect(!curated.map(\.album).contains("One More Time - Single"))
}

@Test func oneDatabaseAloneDoesNotHideTheEP() {
    // Could be a label sampler or a later re-release.
    let curated = SmallModelEvidence.curated(
        [release(.itunes, "Summer Sampler Vol. 2"), release(.itunes, "Midnight City - EP")],
        fileTitle: "Midnight City", fileDuration: nil
    )
    #expect(curated.map(\.album).contains("Midnight City - EP"))
}

@Test func anEPWithItsOwnNameIsNeverHidden() {
    // A real EP: not named after the song on it.
    let curated = SmallModelEvidence.curated(
        [
            release(.wikipedia, "Later Album", title: "Track Two"),
            release(.itunes, "Later Album", title: "Track Two"),
            release(.itunes, "Sunburn - EP", title: "Track Two")
        ],
        fileTitle: "Track Two", fileDuration: nil
    )
    #expect(curated.map(\.album).contains("Sunburn - EP"))
}

@Test func anEPWikipediaNamesAsTheSongsHomeIsKept() {
    // "…title track of his EP Bangarang": the EP *is* the album.
    let curated = SmallModelEvidence.curated(
        [release(.wikipedia, "Bangarang", title: "Bangarang"), release(.itunes, "Bangarang - EP", title: "Bangarang")],
        fileTitle: "Bangarang", fileDuration: nil
    )
    #expect(curated.map(\.album).contains("Bangarang - EP"))
}

@Test func aTitleTrackAlbumDoesNotHideItsOwnSingle() {
    // "Thriller" on Thriller: the album is named after the song too.
    let curated = SmallModelEvidence.curated(
        [release(.wikipedia, "Thriller", title: "Thriller"), release(.itunes, "Thriller - Single", title: "Thriller")],
        fileTitle: "Thriller", fileDuration: nil
    )
    #expect(curated.count == 2)
}

@Test func theFilesOwnAlbumTagIsNeverHidden() {
    let curated = SmallModelEvidence.curated(
        [release(.wikipedia, "Hurry Up, We're Dreaming"), release(.itunes, "Midnight City - EP")],
        fileTitle: "Midnight City", fileDuration: nil, fileAlbum: "Midnight City - EP"
    )
    #expect(curated.map(\.album).contains("Midnight City - EP"))
}

@Test func aVersionedFileTitleStillMatchesItsLeadSingle() {
    // "(Original Mix)" is version wording, not part of the song's name.
    let curated = SmallModelEvidence.curated(
        [release(.wikipedia, "Hurry Up, We're Dreaming"), release(.itunes, "Midnight City - EP")],
        fileTitle: "Midnight City (Original Mix)", fileDuration: nil
    )
    #expect(curated.map(\.album) == ["Hurry Up, We're Dreaming"])
}

@Test func karaokeStyleCompilationsAreRecognised() {
    // Seen in the live Midnight City results.
    #expect(SmallModelEvidence.isCompilationLike(
        album: "2013 Pop Volume 3, 50 Instrumental Hits in the Style of Amy Winehouse, Kid Rock, Lmfao", artist: "Done Again"))
}
