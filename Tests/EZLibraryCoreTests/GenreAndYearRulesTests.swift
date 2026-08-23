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

// MARK: - Genre spelling

@Test func everyFormOfHipHopBecomesOneSpelling() {
    // What the sources actually return for the same genre.
    for variant in ["Hip-Hop/Rap", "Rap/Hip Hop", "hip hop", "HIP-HOP", "HipHop",
                    "Rap & Hip-Hop", "rap", "Hip Hop / Rap"] {
        #expect(GenreCanonicalizer.canonical(variant) == "Hip Hop", "\(variant) was not canonicalised")
    }
}

@Test func aGenreWithNoKnownVariantIsLeftAsWritten() {
    // This is not a place to impose a taxonomy on someone's library.
    #expect(GenreCanonicalizer.canonical("Baile Funk") == "Baile Funk")
    #expect(GenreCanonicalizer.canonical("  Jersey Club  ") == "Jersey Club")
    #expect(GenreCanonicalizer.canonical("") == "")
}

@Test func otherSpellingCollisionsAreSettledToo() {
    #expect(GenreCanonicalizer.canonical("R&B") == "R&B")
    #expect(GenreCanonicalizer.canonical("rnb") == "R&B")
    #expect(GenreCanonicalizer.canonical("Drum & Bass") == "Drum & Bass")
    #expect(GenreCanonicalizer.canonical("drum n bass") == "Drum & Bass")
}

@Test func canonicalGenreIsWrittenThroughTheApplyChokePoint() {
    let verification = TrackTagVerification(
        track: Track(seratoStoredPath: "a.mp3", fileURL: URL(fileURLWithPath: "/a.mp3")),
        engineName: "test",
        identityConfidence: 0.9,
        identitySummary: "",
        fields: [
            TagFieldVerification(
                field: .genre, verdict: .incorrect, currentValue: "",
                proposedValue: "Hip-Hop/Rap", confidence: 0.9, evidence: ""
            )
        ]
    )
    #expect(verification.metadataUpdate(applying: [.genre]).genre == "Hip Hop")
}

// MARK: - Which genres count as electronic

@Test func theElectronicFamilyIsRecognised() {
    for genre in ["House", "Deep House", "Techno", "Trance", "Drum & Bass",
                  "Dubstep", "Electronic", "EDM", "Dance", "UK Garage"] {
        #expect(GenreCanonicalizer.isElectronic(genre), "\(genre) should be electronic")
    }
}

@Test func nonElectronicGenresAreNot() {
    for genre in ["Hip Hop", "Rock", "Soul", "Reggae", "Country", "Jazz", "R&B", ""] {
        #expect(!GenreCanonicalizer.isElectronic(genre), "\(genre) should not be electronic")
    }
}

@Test func compoundElectronicGenresAreRecognised() {
    #expect(GenreCanonicalizer.isElectronic("Progressive House / Melodic Techno"))
    #expect(GenreCanonicalizer.isElectronic("Tech House"))
}

// MARK: - Remix year rule

private func remixTrack(title: String, genre: String) -> Track {
    Track(
        seratoStoredPath: "a.mp3",
        fileURL: URL(fileURLWithPath: "/a.mp3"),
        title: title,
        artist: "An Artist",
        genre: genre
    )
}

@Test func aTitleIsRecognisedAsAVersionOnlyFromItsDescriptor() {
    #expect(TagConsensusService.isVersionOfAnotherRecording("Song (Rampa Remix)"))
    #expect(TagConsensusService.isVersionOfAnotherRecording("Song (Extended Mix)"))
    #expect(TagConsensusService.isVersionOfAnotherRecording("Song - Radio Edit"))
    #expect(TagConsensusService.isVersionOfAnotherRecording("Song [Bootleg]"))
    // A song that merely has one of those words in its name is not a version.
    #expect(!TagConsensusService.isVersionOfAnotherRecording("Remix Culture"))
    #expect(!TagConsensusService.isVersionOfAnotherRecording("Editorial"))
    #expect(!TagConsensusService.isVersionOfAnotherRecording("Plain Song"))
}

@Test func aHipHopRemixKeepsTheOriginalSongsYear() {
    // The rule: outside electronic music a remix is still that record, so it
    // carries the year the song came out rather than the remix's release date.
    #expect(TagConsensusService.shouldUseOriginalReleaseYear(
        for: remixTrack(title: "Song (DJ Premier Remix)", genre: "Hip Hop"),
        fingerprintMatches: [],
        candidates: []
    ))
}

@Test func aHouseRemixKeepsItsOwnYear() {
    // In electronic music a remix is a release in its own right.
    #expect(!TagConsensusService.shouldUseOriginalReleaseYear(
        for: remixTrack(title: "Song (Rampa Remix)", genre: "Deep House"),
        fingerprintMatches: [],
        candidates: []
    ))
}

@Test func aTrackThatIsNotAVersionIsUnaffectedByTheRule() {
    #expect(!TagConsensusService.shouldUseOriginalReleaseYear(
        for: remixTrack(title: "Song", genre: "Hip Hop"),
        fingerprintMatches: [],
        candidates: []
    ))
}

@Test func theGenreForTheRuleFallsBackToWhatSourcesSay() {
    // A track with no genre yet still needs the rule applied, so the sources'
    // genre stands in for the missing one.
    let electronicCandidates = [
        OnlineTrackMetadataCandidate(
            source: .itunes, title: "Song", artist: "An Artist", album: "",
            genre: "House", year: nil, bpm: nil
        )
    ]
    #expect(!TagConsensusService.shouldUseOriginalReleaseYear(
        for: remixTrack(title: "Song (Rampa Remix)", genre: ""),
        fingerprintMatches: [],
        candidates: electronicCandidates
    ))
}

@Test func originalReleaseModeTakesTheEarliestYearOnOffer() {
    let claims = [
        TagConsensusService.Claim(sourceName: "iTunes", value: "2015", isFingerprint: false),
        TagConsensusService.Claim(sourceName: "Deezer", value: "2015", isFingerprint: false),
        TagConsensusService.Claim(sourceName: "MusicBrainz", value: "1998", isFingerprint: false)
    ]

    // Normally the best-supported year wins — two sources say 2015.
    #expect(TagConsensusService.yearConsensus(from: claims)?.value == "2015")
    // For a non-electronic remix the original release wins even with one backer.
    #expect(TagConsensusService.yearConsensus(
        from: claims, preferOriginalRelease: true
    )?.value == "1998")
}

@Test func theRemixYearRuleAppliesEndToEnd() {
    let candidates = [
        OnlineTrackMetadataCandidate(
            source: .itunes, title: "Song", artist: "An Artist", album: "Remixes",
            genre: "Hip-Hop/Rap", year: 2015, bpm: nil
        ),
        OnlineTrackMetadataCandidate(
            source: .deezer, title: "Song", artist: "An Artist", album: "Original Album",
            genre: "Rap/Hip Hop", year: 1998, bpm: nil
        )
    ]

    let result = TagConsensusService.consensus(
        for: remixTrack(title: "Song (DJ Premier Remix)", genre: ""),
        fingerprintMatches: [],
        candidates: candidates
    )

    let year = result.fields.first { $0.field == .year }
    #expect(year?.proposedValue == "1998")

    // And the two spellings of hip hop counted as one agreement, not two
    // sources disagreeing.
    let genre = result.fields.first { $0.field == .genre }
    #expect(genre?.proposedValue == "Hip Hop")
    #expect((genre?.confidence ?? 0) >= 0.75)
}

// MARK: - Searching from the file's tags

@Test func theSearchQueryPrefersTheFilesOwnTags() {
    // The database row is what Serato read at import; anything that edited the
    // file since has not necessarily told Serato.
    let track = Track(
        seratoStoredPath: "a.mp3",
        fileURL: URL(fileURLWithPath: "/a.mp3"),
        title: "Stale Title",
        artist: "Stale Artist",
        album: "Stale Album"
    )
    let fileTags = AudioFileTagReader.Tags(
        title: "Real Title", artist: "Real Artist", album: nil
    )

    let query = TagConsensusService.searchQuery(for: track, fileTags: fileTags)
    #expect(query.title == "Real Title")
    #expect(query.artist == "Real Artist")
    // The file has no album, so the library's value fills the gap.
    #expect(query.album == "Stale Album")
}

@Test func theSearchQueryFallsBackWhenTheFileHasNoTags() {
    let track = Track(
        seratoStoredPath: "a.mp3",
        fileURL: URL(fileURLWithPath: "/a.mp3"),
        title: "Stored Title",
        artist: "Stored Artist"
    )
    let query = TagConsensusService.searchQuery(
        for: track,
        fileTags: AudioFileTagReader.Tags(title: nil, artist: nil)
    )
    #expect(query.title == "Stored Title")
    #expect(query.artist == "Stored Artist")
}

@Test func blankFileTagsDoNotBeatStoredValues() {
    let track = Track(
        seratoStoredPath: "a.mp3",
        fileURL: URL(fileURLWithPath: "/a.mp3"),
        title: "Stored Title",
        artist: "Stored Artist"
    )
    let query = TagConsensusService.searchQuery(
        for: track,
        fileTags: AudioFileTagReader.Tags(title: "   ", artist: "")
    )
    #expect(query.title == "Stored Title")
    #expect(query.artist == "Stored Artist")
}
