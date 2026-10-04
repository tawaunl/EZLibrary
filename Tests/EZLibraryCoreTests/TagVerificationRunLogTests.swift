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

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory
        .appendingPathComponent("RunLogTests-\(UUID().uuidString)", isDirectory: true)
}

private func track(_ name: String, genre: String = "") -> Track {
    Track(
        seratoStoredPath: "Music/\(name)",
        fileURL: URL(fileURLWithPath: "/Music/\(name)"),
        title: "Neverender",
        artist: "Justice",
        album: "Hyperdrama",
        genre: genre,
        comment: "",
        year: 2024
    )
}

private func verification(for track: Track, neededSearchPass: Bool) -> TrackTagVerification {
    TrackTagVerification(
        track: track,
        engineName: "Claude (test)",
        identityConfidence: 0.92,
        identitySummary: "Justice — Neverender",
        fields: [
            TagFieldVerification(
                field: .genre, verdict: .incorrect, currentValue: "", proposedValue: "French House",
                confidence: 0.9, evidence: "Label page", sourceURL: URL(string: "https://example.com/label")
            ),
            TagFieldVerification(
                field: .year, verdict: .incorrect, currentValue: "2024", proposedValue: "2023",
                confidence: 0.6, evidence: "Discogs"
            ),
            TagFieldVerification(
                field: .title, verdict: .correct, currentValue: "Neverender", proposedValue: "",
                confidence: 0.95, evidence: "Matches"
            )
        ],
        webSearchCount: neededSearchPass ? 2 : 0,
        usage: TagVerificationUsage(inputTokens: 1_000, outputTokens: 500, cacheWriteTokens: 0, cacheReadTokens: 1_000),
        neededSearchPass: neededSearchPass
    )
}

/// Every line of the log, decoded.
private func records(in log: TagVerificationRunLog) throws -> [[String: Any]] {
    let text = try String(contentsOf: log.fileURL, encoding: .utf8)
    return try text.split(separator: "\n").map { line in
        try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
    }
}

@Test func aRunIsRecordedLineByLineFromSettingsToTotals() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let options = AITagVerificationService.Options(model: .sonnet55)
    let log = try #require(TagVerificationRunLog.start(
        engine: .cloudModel,
        cloudOptions: options,
        trackCount: 3,
        selectionCount: 5,
        appVersion: "1.0.7",
        in: directory
    ))

    let settled = verification(for: track("A.mp3"), neededSearchPass: false)
    let searched = verification(for: track("B.mp3"), neededSearchPass: true)
    log.record(settled, preselected: [settled.fields[0].id])
    log.record(searched, preselected: [])
    log.recordFailure(track: track("C.mp3"), message: "Claude request failed (HTTP 500)")
    log.recordApplied([
        TagVerificationRunLog.AppliedTrack(
            result: settled,
            selectedFieldIDs: [settled.fields[0].id],
            artworkSelected: false,
            artworkFailed: false
        )
    ])
    log.finish(cancelled: false)
    log.finish(cancelled: true) // a second call must not add a line

    let lines = try records(in: log)
    #expect(lines.map { $0["type"] as? String } == ["run", "track", "track", "failure", "applied", "finished"])

    let run = lines[0]
    #expect(run["model"] as? String == "claude-sonnet-5-5")
    #expect(run["effort"] as? String == "high")
    #expect(run["useWebSearch"] as? Bool == true)
    #expect(run["searchEscalationConfidence"] as? Double == 0.8)
    #expect(run["trackCount"] as? Int == 3)
    #expect(run["appVersion"] as? String == "1.0.7")

    let first = lines[1]
    #expect(first["file"] as? String == "A.mp3")
    #expect(first["neededSearchPass"] as? Bool == false)
    // Sonnet 5.5: 1,000 × $2 + 1,000 cache reads × $0.20 + 500 × $10, per million.
    #expect(abs((first["costUSD"] as? Double ?? 0) - 0.0072) < 0.000001)
    let fields = try #require(first["fields"] as? [[String: Any]])
    #expect(fields[0]["field"] as? String == "genre")
    #expect(fields[0]["proposed"] as? String == "French House")
    #expect(fields[0]["preselected"] as? Bool == true)
    #expect(fields[0]["sourceURL"] as? String == "https://example.com/label")
    #expect(fields[1]["preselected"] as? Bool == false)
    #expect(fields[2]["isChange"] as? Bool == false)

    #expect(lines[3]["message"] as? String == "Claude request failed (HTTP 500)")

    let applied = lines[4]
    #expect(applied["outcome"] as? String == "applied")
    let appliedTrack = try #require((applied["tracks"] as? [[String: Any]])?.first)
    #expect((appliedTrack["kept"] as? [[String: Any]])?.map { $0["field"] as? String } == ["genre"])
    #expect((appliedTrack["unticked"] as? [[String: Any]])?.map { $0["field"] as? String } == ["year"])

    let finished = lines[5]
    #expect(finished["cancelled"] as? Bool == false)
    #expect(finished["verified"] as? Int == 2)
    #expect(finished["failed"] as? Int == 1)
    #expect(finished["searchPasses"] as? Int == 1)
    #expect(finished["webSearches"] as? Int == 2)
    #expect((finished["usage"] as? [String: Any])?["cacheReadTokens"] as? Int == 2_000)
    // Both tracks' tokens, plus the second one's two searches at a cent each.
    #expect(abs((finished["costUSD"] as? Double ?? 0) - (0.0072 * 2 + 0.02)) < 0.000001)
}

@Test func freeEnginesAndOtherProvidersAreLoggedWithoutAClaudePrice() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let consensus = try #require(TagVerificationRunLog.start(
        engine: .consensus, cloudOptions: nil, trackCount: 1, selectionCount: 1, in: directory
    ))
    consensus.record(verification(for: track("A.mp3"), neededSearchPass: false), preselected: [])
    consensus.finish(cancelled: true)
    let consensusLines = try records(in: consensus)
    #expect(consensusLines[0]["model"] == nil)
    #expect(consensusLines[1]["costUSD"] == nil)
    #expect(consensusLines[2]["costUSD"] == nil)
    #expect(consensusLines[2]["cancelled"] as? Bool == true)

    // Claude's rates say nothing about another provider's bill.
    var options = AITagVerificationService.Options()
    options.provider = .openAICompatible
    let other = try #require(TagVerificationRunLog.start(
        engine: .cloudModel, cloudOptions: options, trackCount: 1, selectionCount: 1, in: directory
    ))
    other.record(verification(for: track("B.mp3"), neededSearchPass: false), preselected: [])
    let otherLines = try records(in: other)
    #expect(otherLines[0]["provider"] as? String == "openAICompatible")
    #expect(otherLines[0]["model"] == nil)
    #expect(otherLines[1]["costUSD"] == nil)
}

@Test func eachRunGetsItsOwnFile() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let first = try #require(TagVerificationRunLog.start(
        engine: .consensus, cloudOptions: nil, trackCount: 1, selectionCount: 1, in: directory
    ))
    let second = try #require(TagVerificationRunLog.start(
        engine: .consensus, cloudOptions: nil, trackCount: 1, selectionCount: 1, in: directory
    ))
    #expect(first.fileURL != second.fileURL)
    #expect(first.fileURL.pathExtension == "jsonl")
    #expect(first.fileURL.deletingLastPathComponent() == directory)
}

@Test func aDeclinedOrFailedApplyIsRecordedAsSuch() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let log = try #require(TagVerificationRunLog.start(
        engine: .consensus, cloudOptions: nil, trackCount: 1, selectionCount: 1, in: directory
    ))
    let result = verification(for: track("A.mp3"), neededSearchPass: false)
    let decision = TagVerificationRunLog.AppliedTrack(
        result: result, selectedFieldIDs: [], artworkSelected: false, artworkFailed: false
    )
    log.recordApplied([decision], outcome: .declined)
    log.recordApplied([decision], outcome: .failed, error: "disk full")
    log.recordApplied([]) // nothing to say, so nothing is written

    let lines = try records(in: log)
    #expect(lines.count == 3)
    #expect(lines[1]["outcome"] as? String == "declined")
    #expect(lines[2]["outcome"] as? String == "failed")
    #expect(lines[2]["error"] as? String == "disk full")
}

@Test func aLogThatCannotBeCreatedIsSimplyAbsent() {
    // A path under a regular file can never become a directory.
    let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("RunLogBlocker-\(UUID().uuidString)")
    FileManager.default.createFile(atPath: blocker.path, contents: Data())
    defer { try? FileManager.default.removeItem(at: blocker) }

    let log = TagVerificationRunLog.start(
        engine: .consensus, cloudOptions: nil, trackCount: 1, selectionCount: 1,
        in: blocker.appendingPathComponent("runs")
    )
    #expect(log == nil)
}

@Test func logsLiveUnderTheAppsOwnSupportFolder() throws {
    let directory = try #require(TagVerificationRunLog.defaultDirectory())
    #expect(directory.lastPathComponent == "Verification Runs")
    #expect(directory.deletingLastPathComponent().lastPathComponent == "EZLibrary")
}

// MARK: - Timings

@Test func timingsAreLoggedWithEachTrack() throws {
    let directory = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }

    let log = try #require(TagVerificationRunLog.start(
        engine: .onDevice, cloudOptions: nil, trackCount: 2, selectionCount: 2, in: directory
    ))
    let timed = verification(for: track("A.mp3"), neededSearchPass: false)
        .with(timings: TagVerificationTimings(lookupSeconds: 1.25, modelSeconds: 4.5, toolCalls: 2))
    log.record(timed, preselected: [])
    log.record(verification(for: track("B.mp3"), neededSearchPass: false), preselected: [])

    let lines = try records(in: log)
    let timings = try #require(lines[1]["timings"] as? [String: Any])
    #expect(timings["lookupSeconds"] as? Double == 1.25)
    #expect(timings["modelSeconds"] as? Double == 4.5)
    #expect(timings["toolCalls"] as? Int == 2)
    // An engine that measures nothing simply has no timings.
    #expect(lines[2]["timings"] == nil)
}

@Test func attachingTimingsKeepsEverythingElse() {
    let original = verification(for: track("A.mp3"), neededSearchPass: true)
    let timed = original.with(timings: TagVerificationTimings(lookupSeconds: 1, modelSeconds: 2))
    #expect(timed.fields == original.fields)
    #expect(timed.usage == original.usage)
    #expect(timed.neededSearchPass)
    #expect(timed.webSearchCount == original.webSearchCount)
    #expect(timed.timings?.toolCalls == 0)
}

@Test func timingsSurviveTheEmptyFieldFill() {
    let empty = track("A.mp3", genre: "")
    let result = TrackTagVerification(
        track: empty, engineName: "test", identityConfidence: 0.9, identitySummary: "", fields: []
    ).with(timings: TagVerificationTimings(lookupSeconds: 3, modelSeconds: 7))
    let candidate = OnlineTrackMetadataCandidate(
        source: .itunes, title: "Neverender", artist: "Justice", album: "Hyperdrama",
        genre: "Electronic", year: 2024, bpm: nil
    )
    let filled = TagVerificationCoordinator.completingEmptyFields(in: result, candidates: [candidate, candidate])
    #expect(filled.timings == TagVerificationTimings(lookupSeconds: 3, modelSeconds: 7))
}

@Test func durationsConvertToFractionalSeconds() {
    #expect(Duration.milliseconds(1_500).seconds == 1.5)
    #expect(Duration.seconds(12).seconds == 12)
}
