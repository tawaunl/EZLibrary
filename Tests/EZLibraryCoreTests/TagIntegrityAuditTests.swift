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

private func makeTrack(
    filename: String = "Justice - Neverender.mp3",
    title: String = "Neverender",
    artist: String = "Justice",
    album: String = "Hyperdrama",
    genre: String = "Electronic",
    comment: String = "",
    year: Int? = 2024
) -> Track {
    Track(
        seratoStoredPath: "Music/\(filename)",
        fileURL: URL(fileURLWithPath: "/Music/\(filename)"),
        title: title,
        artist: artist,
        album: album,
        genre: genre,
        comment: comment,
        year: year
    )
}

@Test func cleanTrackProducesNoFindings() {
    #expect(TagIntegrityAudit.audit(makeTrack()).isEmpty)
}

@Test func emptyTitleAndArtistAreHighSeverity() {
    let issues = TagIntegrityAudit.audit(makeTrack(title: "", artist: "   "))
    let fields = issues.filter { $0.severity == .high }.map(\.field)
    #expect(fields.contains(.title))
    #expect(fields.contains(.artist))
}

@Test func placeholderValuesAreFlagged() {
    let issues = TagIntegrityAudit.audit(makeTrack(title: "Unknown", artist: "Unknown Artist"))
    #expect(issues.contains { $0.field == .title && $0.severity == .high })
    #expect(issues.contains { $0.field == .artist && $0.severity == .high })
}

@Test func ripperTrackNumberTitlesAreFlagged() {
    #expect(TagIntegrityAudit.isGenericTrackNumberTitle("track 07"))
    #expect(TagIntegrityAudit.isGenericTrackNumberTitle("audio track 3"))
    #expect(TagIntegrityAudit.isGenericTrackNumberTitle("12"))
    #expect(TagIntegrityAudit.isGenericTrackNumberTitle("untitled"))
    // A real song that happens to be a number stays untouched only when it
    // carries more than digits.
    #expect(!TagIntegrityAudit.isGenericTrackNumberTitle("track star"))
    #expect(!TagIntegrityAudit.isGenericTrackNumberTitle("1999"))
}

@Test func promoTextInTagsIsFlagged() {
    let issues = TagIntegrityAudit.audit(makeTrack(
        title: "Neverender (www.bpmsupreme.com)",
        comment: "Downloaded from DJcity"
    ))
    #expect(issues.contains { $0.field == .title })
    #expect(issues.contains { $0.field == .comment })
}

@Test func filenameDisagreementIsFlagged() {
    let issues = TagIntegrityAudit.audit(makeTrack(
        filename: "Fred again.. - Delilah.mp3",
        title: "Neverender",
        artist: "Justice"
    ))
    #expect(issues.contains { $0.field == .title })
    #expect(issues.contains { $0.field == .artist })
}

@Test func cosmeticFilenameDifferencesAreNotDisagreements() {
    // Same track, different punctuation and an extra descriptor in the file
    // name — routine, and must not be reported as a conflict.
    let issues = TagIntegrityAudit.audit(makeTrack(
        filename: "Justice - Neverender (Extended Mix).mp3",
        title: "Neverender",
        artist: "Justice"
    ))
    #expect(!issues.contains { $0.field == .title })
    #expect(!issues.contains { $0.field == .artist })
}

@Test func leadingTrackNumbersAreStrippedFromFilenames() {
    let parsed = TagIntegrityAudit.parseArtistTitle(
        fromFilename: URL(fileURLWithPath: "/Music/03 - Justice - Neverender.mp3")
    )
    #expect(parsed?.artist == "Justice")
    #expect(parsed?.title == "Neverender")
}

@Test func filenamesWithoutASeparatorParseToNil() {
    #expect(TagIntegrityAudit.parseArtistTitle(
        fromFilename: URL(fileURLWithPath: "/Music/Neverender.mp3")
    ) == nil)
}

@Test func titleRepeatingTheArtistIsFlagged() {
    let issues = TagIntegrityAudit.audit(makeTrack(
        filename: "Justice - Justice - Neverender.mp3",
        title: "Justice - Neverender",
        artist: "Justice"
    ))
    #expect(issues.contains { $0.field == .title })
}

@Test func featuredArtistMissingFromArtistFieldIsFlagged() {
    let issues = TagIntegrityAudit.audit(makeTrack(
        filename: "Drake - Sicko Mode (feat. Travis Scott).mp3",
        title: "Sicko Mode (feat. Travis Scott)",
        artist: "Drake"
    ))
    #expect(issues.contains { $0.field == .artist && $0.severity == .low })
}

@Test func featuredArtistPresentInArtistFieldIsNotFlagged() {
    let issues = TagIntegrityAudit.audit(makeTrack(
        filename: "Drake - Sicko Mode.mp3",
        title: "Sicko Mode (feat. Travis Scott)",
        artist: "Drake, Travis Scott"
    ))
    #expect(!issues.contains { $0.field == .artist })
}

@Test func featuredArtistNameIsExtracted() {
    #expect(TagIntegrityAudit.featuredArtistName(in: "Sicko Mode feat. Travis Scott") == "Travis Scott")
    #expect(TagIntegrityAudit.featuredArtistName(in: "Sicko Mode (ft. Travis Scott)") == "Travis Scott")
    #expect(TagIntegrityAudit.featuredArtistName(in: "Neverender") == nil)
}

@Test func implausibleYearsAreFlagged() {
    #expect(TagIntegrityAudit.audit(makeTrack(year: 1832)).contains { $0.field == .year })
    #expect(TagIntegrityAudit.audit(makeTrack(year: 9999)).contains { $0.field == .year })
    #expect(!TagIntegrityAudit.audit(makeTrack(year: 1977)).contains { $0.field == .year })
}

@Test func keyOrBPMInTheGenreFieldIsFlagged() {
    #expect(TagIntegrityAudit.audit(makeTrack(genre: "8A")).contains { $0.field == .genre })
    #expect(TagIntegrityAudit.audit(makeTrack(genre: "128")).contains { $0.field == .genre })
    #expect(!TagIntegrityAudit.audit(makeTrack(genre: "House")).contains { $0.field == .genre })
}

@Test func normalizationIgnoresCaseAccentsAndPunctuation() {
    #expect(TagIntegrityAudit.normalize("Beyoncé — CUFF IT!") == TagIntegrityAudit.normalize("beyonce cuff it"))
    #expect(TagIntegrityAudit.looselyMatches("Neverender (Rampa Remix)", "Neverender"))
    #expect(!TagIntegrityAudit.looselyMatches("Neverender", "Delilah"))
}

@Test func findingsAreSortedBySeverity() {
    let tracks = [
        makeTrack(filename: "a.mp3", genre: ""),
        makeTrack(filename: "b.mp3", title: "")
    ]
    let findings = TagIntegrityAudit.findings(in: tracks)
    #expect(findings.count == 2)
    #expect(findings.first?.highestSeverity == .high)
}

@Test func summaryNamesTheAffectedFields() {
    let findings = TagIntegrityAudit.findings(in: [makeTrack(title: "", artist: "")])
    let summary = TagIntegrityAudit.summary(for: findings)
    #expect(summary.contains("Title"))
    #expect(summary.contains("Artist"))
    #expect(TagIntegrityAudit.summary(for: []).contains("No obvious tag problems"))
}
