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

private func track(
    title: String = "Neverender",
    artist: String = "Justice",
    album: String = "",
    genre: String = "",
    year: Int? = nil,
    duration: TimeInterval? = nil
) -> Track {
    Track(
        seratoStoredPath: "Music/Justice - Neverender.mp3",
        fileURL: URL(fileURLWithPath: "/Music/Justice - Neverender.mp3"),
        title: title,
        artist: artist,
        album: album,
        genre: genre,
        year: year,
        duration: duration
    )
}

private func candidate(
    _ source: OnlineMetadataSource,
    title: String = "Neverender",
    artist: String = "Justice",
    album: String = "",
    genre: String = "",
    year: Int? = nil,
    duration: Double? = nil
) -> OnlineTrackMetadataCandidate {
    OnlineTrackMetadataCandidate(
        source: source,
        title: title,
        artist: artist,
        album: album,
        genre: genre,
        year: year,
        bpm: nil,
        durationSeconds: duration
    )
}

private func fingerprint(
    title: String = "Neverender",
    artist: String = "Justice",
    album: String = "",
    year: Int? = nil,
    confidence: Double? = 0.95
) -> AudioFingerprintSuggestion {
    AudioFingerprintSuggestion(
        provider: "AcoustID",
        title: title,
        artist: artist,
        album: album,
        genre: "",
        year: year,
        confidence: confidence
    )
}

private func field(
    _ result: TrackTagVerification,
    _ name: TagIntegrityAudit.Field
) -> TagFieldVerification? {
    result.fields.first { $0.field == name }
}

// MARK: - The core rule: agreement, not ranking

@Test func twoAgreeingSourcesProposeAChange() {
    let result = TagConsensusService.consensus(
        for: track(album: "Wrong Album"),
        fingerprintMatches: [],
        candidates: [
            candidate(.itunes, album: "Hyperdrama"),
            candidate(.deezer, album: "Hyperdrama")
        ]
    )

    let album = field(result, .album)
    #expect(album?.verdict == .incorrect)
    #expect(album?.proposedValue == "Hyperdrama")
    #expect(album?.evidence.contains("iTunes") == true)
}

@Test func aSingleSourceIsNeverEnoughToChangeATag() {
    // This is the exact failure mode of "Apply Top Hit": one source's best
    // guess applied as if it were fact.
    let result = TagConsensusService.consensus(
        for: track(album: "Wrong Album"),
        fingerprintMatches: [],
        candidates: [candidate(.itunes, album: "Hyperdrama")]
    )

    #expect(field(result, .album)?.verdict == .unverified)
    #expect(result.proposedChanges.isEmpty)
}

@Test func disagreeingSourcesLeaveTheFieldAlone() {
    let result = TagConsensusService.consensus(
        for: track(album: "Existing"),
        fingerprintMatches: [],
        candidates: [
            candidate(.itunes, album: "Album A"),
            candidate(.deezer, album: "Album B"),
            candidate(.musicBrainz, album: "Album C")
        ]
    )

    #expect(field(result, .album)?.verdict == .unverified)
}

@Test func manyResultsFromOneSourceStillCountAsOneOpinion() {
    // Five iTunes rows agreeing with each other is one source, not five.
    let result = TagConsensusService.consensus(
        for: track(album: "Wrong"),
        fingerprintMatches: [],
        candidates: (0..<5).map { _ in candidate(.itunes, album: "Hyperdrama") }
    )

    #expect(field(result, .album)?.verdict == .unverified)
}

@Test func agreementWithTheCurrentValueIsReportedAsCorrect() {
    let result = TagConsensusService.consensus(
        for: track(album: "Hyperdrama"),
        fingerprintMatches: [],
        candidates: [
            candidate(.itunes, album: "Hyperdrama"),
            candidate(.deezer, album: "Hyperdrama")
        ]
    )

    #expect(field(result, .album)?.verdict == .correct)
    #expect(result.proposedChanges.isEmpty)
}

@Test func cosmeticDifferencesAreNotTreatedAsErrors() {
    let result = TagConsensusService.consensus(
        for: track(album: "Hyperdrama"),
        fingerprintMatches: [],
        candidates: [
            candidate(.itunes, album: "HYPERDRAMA"),
            candidate(.deezer, album: "Hyperdrama.")
        ]
    )

    #expect(field(result, .album)?.verdict == .correct)
}

// MARK: - Duration guarding, the DJ-critical part

@Test func candidatesOfTheWrongLengthAreDiscardedBeforeCounting() {
    // The file is a 7-minute extended mix. Two sources agree on the album of
    // the 3-minute radio edit — a different recording, so their agreement must
    // not move anything.
    let result = TagConsensusService.consensus(
        for: track(album: "Extended Album", duration: 420),
        fingerprintMatches: [],
        candidates: [
            candidate(.itunes, album: "Radio Single", duration: 200),
            candidate(.deezer, album: "Radio Single", duration: 202)
        ]
    )

    #expect(field(result, .album)?.verdict == .unverified)
    #expect(result.identitySummary.contains("wrong length"))
}

@Test func candidatesOfTheRightLengthSurviveTheFilter() {
    let result = TagConsensusService.consensus(
        for: track(album: "Wrong", duration: 420),
        fingerprintMatches: [],
        candidates: [
            candidate(.itunes, album: "Hyperdrama", duration: 419),
            candidate(.deezer, album: "Hyperdrama", duration: 424)
        ]
    )

    #expect(field(result, .album)?.verdict == .incorrect)
    #expect(field(result, .album)?.proposedValue == "Hyperdrama")
}

@Test func candidatesWithoutADurationAreKept() {
    // MusicBrainz and Discogs report no length here. Discarding them would
    // throw away the best sources.
    let filtered = TagConsensusService.candidatesMatchingDuration(
        [candidate(.musicBrainz), candidate(.discogs)],
        fileDuration: 420,
        tolerance: 12
    )
    #expect(filtered.count == 2)
}

@Test func afileWithoutADurationDisablesTheFilter() {
    let filtered = TagConsensusService.candidatesMatchingDuration(
        [candidate(.itunes, duration: 100), candidate(.deezer, duration: 900)],
        fileDuration: nil,
        tolerance: 12
    )
    #expect(filtered.count == 2)
}

// MARK: - Version descriptors

@Test func aConsensusTitleNeverStripsTheVersionDescriptor() {
    // Databases return the plain song title. Applying that verbatim would turn
    // "Neverender (Extended Mix)" into "Neverender" and lose what the DJ owns.
    let result = TagConsensusService.consensus(
        for: track(title: "Neverendr (Extended Mix)"),
        fingerprintMatches: [],
        candidates: [
            candidate(.itunes, title: "Neverender"),
            candidate(.deezer, title: "Neverender")
        ]
    )

    let title = field(result, .title)
    #expect(title?.verdict == .incorrect)
    #expect(title?.proposedValue == "Neverender (Extended Mix)")
}

// MARK: - Fingerprint weighting

@Test func aFingerprintCountsAsASourceAndRaisesConfidence() {
    let withFingerprint = TagConsensusService.consensus(
        for: track(album: "Wrong"),
        fingerprintMatches: [fingerprint(album: "Hyperdrama")],
        candidates: [candidate(.itunes, album: "Hyperdrama")]
    )
    let withoutFingerprint = TagConsensusService.consensus(
        for: track(album: "Wrong"),
        fingerprintMatches: [],
        candidates: [candidate(.itunes, album: "Hyperdrama"), candidate(.deezer, album: "Hyperdrama")]
    )

    #expect(field(withFingerprint, .album)?.verdict == .incorrect)
    // Same number of agreeing sources, but fingerprint evidence is stronger.
    let fingerprintConfidence = field(withFingerprint, .album)?.confidence ?? 0
    let textConfidence = field(withoutFingerprint, .album)?.confidence ?? 0
    #expect(fingerprintConfidence > textConfidence)
}

@Test func identityConfidenceFollowsTheFingerprintScore() {
    let strong = TagConsensusService.consensus(
        for: track(),
        fingerprintMatches: [fingerprint(confidence: 0.96)],
        candidates: []
    )
    let none = TagConsensusService.consensus(
        for: track(),
        fingerprintMatches: [],
        candidates: [candidate(.itunes)]
    )

    #expect(strong.identityConfidence > 0.9)
    #expect(none.identityConfidence < 0.7)
    #expect(strong.identitySummary.contains("fingerprint"))
}

// MARK: - Empty fields

@Test func anEmptyFieldIsFilledOnlyWhenSourcesAgree() {
    let result = TagConsensusService.consensus(
        for: track(year: nil),
        fingerprintMatches: [],
        candidates: [
            candidate(.itunes, year: 2024),
            candidate(.musicBrainz, year: 2024)
        ]
    )

    let year = field(result, .year)
    #expect(year?.verdict == .incorrect)
    #expect(year?.proposedValue == "2024")
    #expect(year?.evidence.contains("empty") == true)
}

@Test func anEmptyFieldNoSourceCanFillStaysUnverified() {
    let result = TagConsensusService.consensus(
        for: track(genre: ""),
        fingerprintMatches: [],
        candidates: [candidate(.deezer)]
    )

    let genre = field(result, .genre)
    #expect(genre?.verdict == .unverified)
    #expect(genre?.proposedValue.isEmpty == true)
}

@Test func aFieldNoSourceOffersIsReportedAsSuch() {
    let result = TagConsensusService.consensus(
        for: track(),
        fingerprintMatches: [],
        candidates: []
    )
    #expect(result.fields.allSatisfy { $0.verdict == .unverified })
    #expect(result.proposedChanges.isEmpty)
}

// MARK: - Supporting logic

@Test func winningValueCountsDistinctSourcesNotClaims() {
    let claims = [
        TagConsensusService.Claim(sourceName: "iTunes", value: "A", isFingerprint: false),
        TagConsensusService.Claim(sourceName: "iTunes", value: "A", isFingerprint: false),
        TagConsensusService.Claim(sourceName: "Deezer", value: "B", isFingerprint: false),
        TagConsensusService.Claim(sourceName: "MusicBrainz", value: "B", isFingerprint: false)
    ]
    let winner = TagConsensusService.winningValue(from: claims)
    #expect(winner?.value == "B")
    #expect(winner?.sources.count == 2)
}

@Test func tiesAreBrokenByTheMoreAuthoritativeSource() {
    let claims = [
        TagConsensusService.Claim(sourceName: "Deezer", value: "Deezer Says", isFingerprint: false),
        TagConsensusService.Claim(sourceName: "AcoustID", value: "Fingerprint Says", isFingerprint: true)
    ]
    #expect(TagConsensusService.winningValue(from: claims)?.value == "Fingerprint Says")
}

@Test func confidenceRisesWithAgreementAndIsCapped() {
    #expect(TagConsensusService.confidence(agreeing: 1, fingerprintAgrees: false)
            < TagConsensusService.confidence(agreeing: 2, fingerprintAgrees: false))
    #expect(TagConsensusService.confidence(agreeing: 2, fingerprintAgrees: false)
            < TagConsensusService.confidence(agreeing: 3, fingerprintAgrees: false))
    #expect(TagConsensusService.confidence(agreeing: 9, fingerprintAgrees: true) <= 0.97)
}

@Test func sourceListsReadAsProse() {
    #expect(TagConsensusService.formattedList(["iTunes"]) == "iTunes")
    #expect(TagConsensusService.formattedList(["iTunes", "Deezer"]) == "iTunes and Deezer")
    #expect(TagConsensusService.formattedList(["A", "B", "C"]) == "A, B, and C")
}

@Test func consensusRunsWithNoNetworkAndNoKeys() {
    // The whole point of this tier: it produces a full verdict set from
    // whatever evidence it is handed, with no credential anywhere.
    let result = TagConsensusService.consensus(
        for: track(album: "Wrong"),
        fingerprintMatches: [],
        candidates: [candidate(.itunes, album: "Right"), candidate(.deezer, album: "Right")]
    )
    #expect(result.engineName == "Cross-source consensus")
    #expect(result.usage == nil)
    #expect(result.fields.count == AITagVerificationService.verifiableFields.count)
}

// MARK: - On-device proposal sanitising
//
// These guard the repairs applied to a small model's output. They live here
// rather than in a dedicated file because the on-device engine only compiles
// on macOS 26, and the rest of the suite must keep building without it.

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Test func aProposedTitleCarryingTheArtistIsRepaired() {
    // Observed live: asked for a title, the on-device model answered
    // "Justice - D.A.N.C.E. (Extended Mix)" because the file name looks that
    // way. Applying it verbatim would corrupt the field.
    let subject = track(title: "D.A.N.C.E. (Extended Mix)", artist: "Justice")
    let repaired = OnDeviceTagVerificationService.sanitized(
        "Justice - D.A.N.C.E. (Extended Mix)",
        for: .title,
        track: subject
    )
    #expect(repaired == "D.A.N.C.E. (Extended Mix)")
}

@available(macOS 26.0, *)
@Test func artistPrefixStrippingHandlesSeveralSeparators() {
    #expect(OnDeviceTagVerificationService.strippingArtistPrefix(from: "Justice - Song", artist: "Justice") == "Song")
    #expect(OnDeviceTagVerificationService.strippingArtistPrefix(from: "Justice: Song", artist: "Justice") == "Song")
    #expect(OnDeviceTagVerificationService.strippingArtistPrefix(from: "justice - Song", artist: "Justice") == "Song")
    // A song whose real title starts with the artist's name is left alone.
    #expect(OnDeviceTagVerificationService.strippingArtistPrefix(from: "Justice For All", artist: "Justice") == "Justice For All")
    #expect(OnDeviceTagVerificationService.strippingArtistPrefix(from: "Song", artist: "") == "Song")
}

@available(macOS 26.0, *)
@Test func aDroppedVersionDescriptorIsReattachedToTheProposal() {
    let subject = track(title: "Neverender (Extended Mix)", artist: "Justice")
    let repaired = OnDeviceTagVerificationService.sanitized("Neverender", for: .title, track: subject)
    #expect(repaired == "Neverender (Extended Mix)")
}

@available(macOS 26.0, *)
@Test func aProposedYearThatIsNotANumberIsDiscarded() {
    let subject = track()
    #expect(OnDeviceTagVerificationService.sanitized("nineties", for: .year, track: subject).isEmpty)
    #expect(OnDeviceTagVerificationService.sanitized("1997", for: .year, track: subject) == "1997")
}
#endif

// MARK: - Year
//
// Year had its own bug: the sources are not answering the same question, so
// exact-match consensus left it unverified on nearly everything.

@Test func iTunesAndMusicBrainzYearsOneApartStillFillTheYear() {
    // Measured from the real APIs for Daft Punk — Around The World: iTunes
    // reports the matched release (1997), MusicBrainz the first release (1996).
    // Before the fix these cancelled out and no year was ever proposed.
    let result = TagConsensusService.consensus(
        for: track(year: nil),
        fingerprintMatches: [],
        candidates: [
            candidate(.itunes, year: 1997),
            candidate(.musicBrainz, year: 1996)
        ]
    )

    let year = field(result, .year)
    #expect(year?.verdict == .incorrect)
    // The earliest is the original release year, which is what a library tags.
    #expect(year?.proposedValue == "1996")
    #expect((year?.confidence ?? 0) >= 0.75)
}

@Test func aRemasterYearDoesNotMergeWithTheOriginal() {
    // 1977 against a 2015 remaster is a real difference, not a release-date
    // technicality, so they must not be treated as corroborating.
    let claims = [
        TagConsensusService.Claim(sourceName: "MusicBrainz", value: "1977", isFingerprint: false),
        TagConsensusService.Claim(sourceName: "iTunes", value: "2015", isFingerprint: false)
    ]
    let resolved = TagConsensusService.yearConsensus(from: claims)
    #expect(resolved?.sources.count == 1)
    #expect(resolved?.value == "1977")
}

@Test func theYearClusterWithTheMostSourcesWins() {
    let claims = [
        TagConsensusService.Claim(sourceName: "iTunes", value: "2015", isFingerprint: false),
        TagConsensusService.Claim(sourceName: "MusicBrainz", value: "1999", isFingerprint: false),
        TagConsensusService.Claim(sourceName: "Deezer", value: "2000", isFingerprint: false),
        TagConsensusService.Claim(sourceName: "AcoustID", value: "1999", isFingerprint: true)
    ]
    let resolved = TagConsensusService.yearConsensus(from: claims)
    #expect(resolved?.value == "1999")
    #expect(resolved?.sources.count == 3)
}

@Test func nonsenseYearsAreIgnored() {
    let claims = [
        TagConsensusService.Claim(sourceName: "iTunes", value: "not a year", isFingerprint: false),
        TagConsensusService.Claim(sourceName: "Deezer", value: "1200", isFingerprint: false)
    ]
    #expect(TagConsensusService.yearConsensus(from: claims) == nil)
}

@Test func yearsAreParsedOutOfFullDates() {
    let claims = [
        TagConsensusService.Claim(sourceName: "iTunes", value: "1997-01-20", isFingerprint: false),
        TagConsensusService.Claim(sourceName: "MusicBrainz", value: "1997", isFingerprint: false)
    ]
    #expect(TagConsensusService.yearConsensus(from: claims)?.value == "1997")
}

// MARK: - Empty fields accept a single source as a suggestion

@Test func oneSourceCanSuggestIntoAnEmptyFieldButNotOverwrite() {
    let empty = TagConsensusService.consensus(
        for: track(genre: ""),
        fingerprintMatches: [],
        candidates: [candidate(.itunes, genre: "House")]
    )
    let populated = TagConsensusService.consensus(
        for: track(genre: "Techno"),
        fingerprintMatches: [],
        candidates: [candidate(.itunes, genre: "House")]
    )

    #expect(field(empty, .genre)?.verdict == .incorrect)
    #expect(field(empty, .genre)?.proposedValue == "House")
    // A value someone already chose still needs corroboration to be replaced.
    #expect(field(populated, .genre)?.verdict == .unverified)
}

@Test func aSingleSourceSuggestionStaysBelowTheAutoApplyBar() {
    // It should appear in the review sheet, not be written by a bulk run.
    let result = TagConsensusService.consensus(
        for: track(genre: ""),
        fingerprintMatches: [],
        candidates: [candidate(.itunes, genre: "House")]
    )
    let confidence = field(result, .genre)?.confidence ?? 1
    #expect(confidence < TagVerificationCoordinator.confidenceThreshold(for: .consensus))

    #expect(TagVerificationCoordinator.autoApplicableFields(
        in: result,
        engine: .consensus,
        limitedTo: [.artist, .album, .genre, .year],
        onlyFillEmpty: true
    ).isEmpty)
}

@Test func aSingleSourceSuggestionReadsAsOneSourceNotAgreement() {
    let result = TagConsensusService.consensus(
        for: track(genre: ""),
        fingerprintMatches: [],
        candidates: [candidate(.itunes, genre: "House")]
    )
    let evidence = field(result, .genre)?.evidence ?? ""
    #expect(evidence.contains("says"))
    #expect(!evidence.contains("agree it"))
}
