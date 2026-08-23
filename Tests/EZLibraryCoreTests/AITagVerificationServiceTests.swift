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

private func sampleTrack() -> Track {
    Track(
        seratoStoredPath: "Music/Justice - Neverender.mp3",
        fileURL: URL(fileURLWithPath: "/Music/Justice - Neverender.mp3"),
        title: "Neverender",
        artist: "Justice",
        album: "Unknown",
        genre: "",
        comment: "my cue notes",
        year: nil
    )
}

private func verification(from json: String, track: Track = sampleTrack()) throws -> AITagVerificationService.TrackVerification {
    try AITagVerificationService.parse(
        text: json,
        for: track,
        provenance: AITagVerificationService.Provenance(
            engineLabel: "Claude (test)",
            sourceURLs: [URL(string: "https://example.com/release")!],
            webSearchCount: 2,
            usage: TagVerificationUsage(inputTokens: 100, outputTokens: 50)
        )
    )
}

private let fullVerdictJSON = """
{
  "identity_confidence": 0.94,
  "identity_summary": "Justice — Neverender, from Hyperdrama (2024).",
  "fields": [
    {"field": "title", "verdict": "correct", "proposed_value": "", "confidence": 0.95,
     "evidence": "Matches the release listing.", "source_url": "https://example.com/release"},
    {"field": "album", "verdict": "incorrect", "proposed_value": "Hyperdrama", "confidence": 0.9,
     "evidence": "The single appears on Hyperdrama.", "source_url": "https://example.com/album"},
    {"field": "year", "verdict": "incorrect", "proposed_value": "2024", "confidence": 0.88,
     "evidence": "Released 2024-04-26.", "source_url": "https://example.com/album"},
    {"field": "genre", "verdict": "unverified", "proposed_value": "", "confidence": 0.2,
     "evidence": "Sources disagree on genre.", "source_url": ""}
  ]
}
"""

@Test func verdictsAreParsedWithSourcesAndConfidence() throws {
    let result = try verification(from: fullVerdictJSON)

    #expect(result.identityConfidence == 0.94)
    #expect(result.identitySummary.contains("Neverender"))
    #expect(result.fields.count == 4)
    #expect(result.webSearchCount == 2)
    #expect(result.sourceURLs.first?.absoluteString == "https://example.com/release")

    let album = try #require(result.fields.first { $0.field == .album })
    #expect(album.verdict == .incorrect)
    #expect(album.proposedValue == "Hyperdrama")
    #expect(album.currentValue == "Unknown")
    #expect(album.sourceURL?.absoluteString == "https://example.com/album")
    #expect(album.isChange)
}

@Test func onlyContradictedFieldsCountAsChanges() throws {
    let result = try verification(from: fullVerdictJSON)
    let changed = result.proposedChanges.map(\.field)

    #expect(changed.contains(.album))
    #expect(changed.contains(.year))
    // A confirmed field and an unverifiable one both leave the tag alone.
    #expect(!changed.contains(.title))
    #expect(!changed.contains(.genre))
}

@Test func anIncorrectVerdictWithNoReplacementIsNotAChange() throws {
    let json = """
    {"identity_confidence": 0.5, "identity_summary": "", "fields": [
      {"field": "genre", "verdict": "incorrect", "proposed_value": "  ", "confidence": 0.6,
       "evidence": "Genre is wrong but I could not establish the right one.", "source_url": ""}
    ]}
    """
    #expect(try verification(from: json).proposedChanges.isEmpty)
}

@Test func aProposalIdenticalToTheCurrentValueIsNotAChange() throws {
    let json = """
    {"identity_confidence": 0.9, "identity_summary": "", "fields": [
      {"field": "title", "verdict": "incorrect", "proposed_value": "Neverender", "confidence": 0.9,
       "evidence": "", "source_url": ""}
    ]}
    """
    #expect(try verification(from: json).proposedChanges.isEmpty)
}

@Test func applyingASubsetLeavesEveryOtherFieldUntouched() throws {
    let track = sampleTrack()
    let result = try verification(from: fullVerdictJSON, track: track)
    let update = result.metadataUpdate(applying: [.album])

    #expect(update.album == "Hyperdrama")
    // Year was also proposed but not selected, so it must stay as it was.
    #expect(update.year == nil)
    #expect(update.title == track.title)
    #expect(update.artist == track.artist)
    #expect(update.comment == "my cue notes")
}

@Test func applyingTheYearConvertsItToANumber() throws {
    let result = try verification(from: fullVerdictJSON)
    #expect(result.metadataUpdate(applying: [.year]).year == 2024)
}

@Test func anUnparseableYearIsDroppedRatherThanWritten() throws {
    let json = """
    {"identity_confidence": 0.9, "identity_summary": "", "fields": [
      {"field": "year", "verdict": "incorrect", "proposed_value": "sometime in the nineties",
       "confidence": 0.4, "evidence": "", "source_url": ""}
    ]}
    """
    let track = Track(
        seratoStoredPath: "a.mp3",
        fileURL: URL(fileURLWithPath: "/a.mp3"),
        year: 1999
    )
    let update = try verification(from: json, track: track).metadataUpdate(applying: [.year])
    #expect(update.year == 1999)
}

@Test func verdictJSONWrappedInProseIsStillParsed() {
    // The fallback path for when the API declined the schema and the model
    // answered with the object embedded in a sentence.
    let text = "Here is my assessment:\n```json\n{\"identity_confidence\": 0.8, \"fields\": []}\n```\nHope that helps."
    let object = AITagVerificationService.jsonObject(from: text)
    #expect(object?["identity_confidence"] as? Double == 0.8)
}

@Test func aNonJSONReplyIsReportedRatherThanGuessedAt() {
    #expect(AITagVerificationService.jsonObject(from: "I could not identify this track.") == nil)
}

@Test func unknownFieldNamesInTheReplyAreSkipped() throws {
    let json = """
    {"identity_confidence": 0.9, "identity_summary": "", "fields": [
      {"field": "bpm", "verdict": "incorrect", "proposed_value": "128", "confidence": 0.9,
       "evidence": "", "source_url": ""},
      {"field": "album", "verdict": "incorrect", "proposed_value": "Hyperdrama", "confidence": 0.9,
       "evidence": "", "source_url": ""}
    ]}
    """
    let result = try verification(from: json)
    #expect(result.fields.count == 1)
    #expect(result.fields.first?.field == .album)
}

@Test func nonHTTPSourceValuesDoNotBecomeURLs() throws {
    let json = """
    {"identity_confidence": 0.9, "identity_summary": "", "fields": [
      {"field": "album", "verdict": "incorrect", "proposed_value": "Hyperdrama", "confidence": 0.9,
       "evidence": "", "source_url": "the liner notes"}
    ]}
    """
    #expect(try verification(from: json).fields.first?.sourceURL == nil)
}

@Test func theResponseSchemaIsValidJSONAndClosed() throws {
    let schema = AITagVerificationService.responseSchema
    #expect(JSONSerialization.isValidJSONObject(schema))
    // Structured outputs require every object to be closed.
    #expect(schema["additionalProperties"] as? Bool == false)

    let properties = try #require(schema["properties"] as? [String: Any])
    let items = try #require((properties["fields"] as? [String: Any])?["items"] as? [String: Any])
    #expect(items["additionalProperties"] as? Bool == false)

    let required = try #require(items["required"] as? [String])
    #expect(Set(required) == ["field", "verdict", "proposed_value", "confidence", "evidence", "source_url"])
}

@Test func costEstimatesScaleWithTrackCountAndModel() {
    let opus = AITagVerificationService.Options(model: .opus5)
    let haiku = AITagVerificationService.Options(model: .haiku45)

    let opusTen = AITagVerificationService.estimatedCost(trackCount: 10, options: opus)
    #expect(opusTen > AITagVerificationService.estimatedCost(trackCount: 1, options: opus))
    #expect(opusTen > AITagVerificationService.estimatedCost(trackCount: 10, options: haiku))

    var noSearch = opus
    noSearch.useWebSearch = false
    #expect(AITagVerificationService.estimatedCost(trackCount: 10, options: noSearch) < opusTen)
    #expect(AITagVerificationService.estimatedCostText(trackCount: 10, options: opus).contains("$"))
}

@Test func evidenceIncludesTheTagsFilenameAndAuditFlags() async {
    var options = AITagVerificationService.Options()
    // Keep this offline: the network sources are best-effort evidence, not
    // what this test is about.
    options.useFingerprint = false
    options.useOnlineCandidates = false

    let evidence = await AITagVerificationService.gatherEvidence(for: sampleTrack(), options: options)

    #expect(evidence.contains("FILE: Justice - Neverender.mp3"))
    #expect(evidence.contains("title: Neverender"))
    #expect(evidence.contains("genre: (empty)"))
    #expect(evidence.contains("AUTOMATED CHECKS FLAGGED:"))
    #expect(evidence.contains("placeholder"))
    #expect(evidence.contains("VERIFY THESE FIELDS: title, artist, album, genre, year"))
}

@Test func verifyingAnEmptySelectionFinishesWithoutCallingTheAPI() async {
    var events: [AITagVerificationService.Event] = []
    for await event in AITagVerificationService.verify(tracks: [], apiKey: nil) {
        events.append(event)
    }

    #expect(events.count == 1)
    if case let .finished(verified, failed) = events[0] {
        #expect(verified == 0)
        #expect(failed == 0)
    } else {
        Issue.record("expected a finished event, got \(events[0])")
    }
}

@Test func aMissingAPIKeyAbortsTheRunWithOneClearMessage() async {
    let defaults = TestDefaults.inMemory()

    // Only exercised when the environment has no key either; skip rather than
    // fail on a machine that exports one.
    guard ClaudeAPIClient.apiKey(userDefaults: defaults) == nil else { return }

    var messages: [String] = []
    for await event in AITagVerificationService.verify(tracks: [sampleTrack()]) {
        if case let .aborted(message) = event {
            messages.append(message)
        }
    }

    #expect(messages.count == 1)
    #expect(messages.first?.contains("Anthropic API key") == true)
}

@Test func braceInPreambleProseDoesNotDefeatJSONExtraction() {
    let text = "I checked {the album listing} and concluded:\n"
        + "{\"identity_confidence\": 0.77, \"identity_summary\": \"ok\", \"fields\": []}"
    let object = AITagVerificationService.jsonObject(from: text)
    #expect(object?["identity_confidence"] as? Double == 0.77)
    #expect(object?["identity_summary"] as? String == "ok")
}
