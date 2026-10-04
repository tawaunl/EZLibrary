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

private typealias Service = AITagVerificationService

private func track() -> Track {
    Track(
        seratoStoredPath: "Music/M83 - Midnight City.mp3",
        fileURL: URL(fileURLWithPath: "/nonexistent/M83 - Midnight City.mp3"),
        title: "Midnight City",
        artist: "M83",
        album: "",
        genre: "Electronic",
        comment: "",
        year: 2011
    )
}

/// Every field "correct" at `confidence`, the album filled at `albumConfidence`.
private func verdictJSON(identity: Double = 0.95, confidence: Double = 0.95, albumConfidence: Double = 0.95) -> String {
    let fields = Service.verifiableFields.map { field -> String in
        let isAlbum = field == .album
        let verdict = isAlbum ? "incorrect" : "correct"
        let value = isAlbum ? "Hurry Up, We're Dreaming" : ""
        return """
        {"field":"\(field.rawValue)","verdict":"\(verdict)","proposed_value":"\(value)",\
        "confidence":\(isAlbum ? albumConfidence : confidence),"evidence":"test","source_url":""}
        """
    }
    return """
    {"identity_confidence":\(identity),"identity_summary":"M83 — Midnight City",\
    "fields":[\(fields.joined(separator: ","))]}
    """
}

private func verification(_ json: String) throws -> Service.TrackVerification {
    try Service.parse(text: json, for: track(), provenance: Service.Provenance(engineLabel: "test"))
}

private let artwork = ArtworkProposal(
    sourceName: "iTunes",
    url: URL(string: "https://example.invalid/600x600bb.jpg")!,
    fileIsMissingArtwork: true,
    albumTitle: "Hurry Up, We're Dreaming"
)

// MARK: - When a track is worth retrying

@Test func aSettledAnswerWithArtIsGoodEnoughToSkipITunes() throws {
    let settled = try verification(verdictJSON())
    #expect(Service.isGoodEnough(settled, fileHasArtwork: true))
    // No art in the file and none on offer: iTunes may have some.
    #expect(!Service.isGoodEnough(settled, fileHasArtwork: false))
    #expect(Service.isGoodEnough(settled.with(artwork: artwork), fileHasArtwork: false))
}

@Test func anUnsureAnswerIsNotGoodEnough() throws {
    #expect(!Service.isGoodEnough(try verification(verdictJSON(albumConfidence: 0.6)), fileHasArtwork: true))
    #expect(!Service.isGoodEnough(try verification(verdictJSON(identity: 0.7)), fileHasArtwork: true))
}

@Test func aSecondAnswerReplacesTheFirstOnlyWhenItIsBetter() throws {
    let unsure = try verification(verdictJSON(albumConfidence: 0.6))
    let sure = try verification(verdictJSON())
    #expect(Service.isImprovement(sure, over: unsure))
    #expect(!Service.isImprovement(unsure, over: sure))
    // Same fields settled: art where there was none wins; a tie keeps the first.
    #expect(Service.isImprovement(sure.with(artwork: artwork), over: sure))
    #expect(!Service.isImprovement(sure, over: sure))
}

@Test func aReplacementCarriesWhatBothAnswersCost() throws {
    let first = TrackTagVerification(
        track: track(), engineName: "a", identityConfidence: 0.7, identitySummary: "", fields: [],
        webSearchCount: 2, usage: TagVerificationUsage(inputTokens: 100, outputTokens: 10), neededSearchPass: true
    )
    let second = TrackTagVerification(
        track: track(), engineName: "b", identityConfidence: 0.9, identitySummary: "", fields: [],
        usage: TagVerificationUsage(inputTokens: 50, outputTokens: 5)
    )
    let replaced = second.replacing(first)
    #expect(replaced.usage?.inputTokens == 150)
    #expect(replaced.usage?.outputTokens == 15)
    #expect(replaced.webSearchCount == 2)
    #expect(replaced.neededSearchPass)
    #expect(replaced.identityConfidence == 0.9)
}

@Test func iTunesResultsGoFirstWhenAddedToEvidence() {
    let deezer = OnlineTrackMetadataCandidate(
        source: .deezer, title: "Midnight City", artist: "M83", album: "Midnight City", genre: "", year: 2011, bpm: nil
    )
    let itunes = OnlineTrackMetadataCandidate(
        source: .itunes, title: "Midnight City", artist: "M83", album: "Hurry Up, We're Dreaming",
        genre: "Electronic", year: 2011, bpm: nil
    )
    let evidence = Service.Evidence(
        leadingLines: ["CURRENT TAGS:"],
        candidates: [deezer],
        query: .init(title: "Midnight City", artist: "M83", album: ""),
        missedITunes: true
    )
    let added = evidence.adding(iTunes: [itunes])
    #expect(!added.missedITunes)
    #expect(added.candidates.map(\.source) == [.itunes, .deezer])
    #expect(added.text.contains("[iTunes] M83 — Midnight City | album: Hurry Up, We're Dreaming"))
}

// MARK: - The worker on the wire

/// Answers iTunes searches with `itunesBody` and Claude with `claudeReply`,
/// counting each.
private final class RetryStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var itunesBody = Data()
    nonisolated(unsafe) static var claudeReply = ""
    nonisolated(unsafe) static var itunesRequests = 0
    nonisolated(unsafe) static var claudeBodies: [String] = []
    private static let lock = NSLock()

    static func reset(itunesBody: Data, claudeReply: String) {
        lock.lock()
        defer { lock.unlock() }
        self.itunesBody = itunesBody
        self.claudeReply = claudeReply
        itunesRequests = 0
        claudeBodies = []
    }

    static var counts: (itunes: Int, claude: [String]) {
        lock.lock()
        defer { lock.unlock() }
        return (itunesRequests, claudeBodies)
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let data: Data
        Self.lock.lock()
        if request.url?.host == "itunes.apple.com" {
            Self.itunesRequests += 1
            data = Self.itunesBody
        } else {
            Self.claudeBodies.append(Self.readBody(of: request))
            let payload: [String: Any] = [
                "content": [["type": "text", "text": Self.claudeReply]],
                "stop_reason": "end_turn",
                "usage": ["input_tokens": 1000, "output_tokens": 100,
                          "cache_creation_input_tokens": 0, "cache_read_input_tokens": 900]
            ]
            data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        }
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    private static func readBody(of request: URLRequest) -> String {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let read = stream.read(&buffer, maxLength: buffer.count)
                guard read > 0 else { break }
                data.append(buffer, count: read)
            }
        }
        return String(decoding: data, as: UTF8.self)
    }
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [RetryStubProtocol.self]
    return URLSession(configuration: configuration)
}

private let itunesHit = Data("""
{"resultCount":1,"results":[{"trackName":"Midnight City","artistName":"M83","collectionName":"Hurry Up, We're Dreaming",\
"primaryGenreName":"Electronic","releaseDate":"2011-08-16T07:00:00Z"}]}
""".utf8)

private let itunesEmpty = Data(#"{"resultCount":0,"results":[]}"#.utf8)

/// These share `RetryStubProtocol` and the iTunes pacer, so they run one at a time.
@Suite(.serialized)
struct ITunesRetryWorkerTests {
    init() async {
        RequestPacer.delayScale = 0
        await RequestPacer.itunes.resetForTesting()
    }

    /// Runs the worker over one track whose run has already finished, and
    /// returns what it reported.
    private func runWorker(query title: String, isStillOpen: Bool) async throws -> [TagVerificationEvent] {
        let queue = Service.ITunesRetryQueue()
        let evidence = Service.Evidence(
            leadingLines: ["CURRENT TAGS:"],
            candidates: [],
            query: .init(title: title, artist: "M83", album: ""),
            missedITunes: true
        )
        _ = await queue.add(.init(track: track(), evidence: evidence, first: try verification(verdictJSON(albumConfidence: 0.6))))
        await queue.markRunDone()

        let (stream, continuation) = AsyncStream<TagVerificationEvent>.makeStream()
        await Service.runITunesRetries(
            queue: queue,
            isStillOpen: { _ in isStillOpen },
            continuation: continuation,
            options: Service.Options(model: .sonnet55, useWebSearch: true, useFingerprint: false),
            apiKey: "test-key",
            session: stubSession(),
            databaseSession: stubSession()
        )
        continuation.finish()
        var events: [TagVerificationEvent] = []
        for await event in stream { events.append(event) }
        return events
    }

    @Test func aTrackThatSkippedITunesIsAskedAgainWithItsResults() async throws {
        RetryStubProtocol.reset(itunesBody: itunesHit, claudeReply: verdictJSON())
        let events = try await runWorker(query: "Midnight City retry", isStillOpen: true)

        let counts = RetryStubProtocol.counts
        #expect(counts.itunes == 1)
        #expect(counts.claude.count == 1)
        // The new question shows iTunes's answer and does not search the web.
        #expect(counts.claude.first?.contains("Hurry Up") == true)
        #expect(counts.claude.first?.contains("web_search") == false)

        let retried = events.compactMap { event -> (TrackTagVerification?, TagVerificationUsage?)? in
            if case let .retried(_, improvement, usage) = event { return (improvement, usage) }
            return nil
        }
        #expect(retried.count == 1)
        #expect(retried.first?.0 != nil)
        #expect(retried.first?.1?.inputTokens == 1000)
        if case let .iTunesRetriesPending(left) = events.last {
            #expect(left == 0)
        } else {
            Issue.record("expected the pending count last, got \(String(describing: events.last))")
        }
    }

    @Test func aTickedOrAppliedTrackIsNotSearchedAgain() async throws {
        RetryStubProtocol.reset(itunesBody: itunesHit, claudeReply: verdictJSON())
        let events = try await runWorker(query: "Midnight City ticked", isStillOpen: false)

        #expect(RetryStubProtocol.counts.itunes == 0)
        #expect(RetryStubProtocol.counts.claude.isEmpty)
        #expect(!events.contains { if case .retried = $0 { return true } else { return false } })
    }

    @Test func iTunesFindingNothingCostsNoSecondAnswer() async throws {
        RetryStubProtocol.reset(itunesBody: itunesEmpty, claudeReply: verdictJSON())
        _ = try await runWorker(query: "Midnight City nothing", isStillOpen: true)

        #expect(RetryStubProtocol.counts.itunes == 1)
        #expect(RetryStubProtocol.counts.claude.isEmpty)
    }

    /// A search skipped while iTunes is busy reports iTunes as missed, rather
    /// than failing or looking like iTunes had no match.
    @Test func aBusyITunesIsReportedAsMissed() async {
        RequestPacer.delayScale = 1
        defer { RequestPacer.delayScale = 0 }
        for _ in 0..<4 { _ = await RequestPacer.itunes.reserveSlot(minimumInterval: 3) }
        RetryStubProtocol.reset(itunesBody: itunesHit, claudeReply: "")

        let outcome = await OnlineTrackMetadataLookupService.lookupOutcome(
            query: .init(title: "Midnight City busy", artist: "M83", album: ""),
            sourceSelection: .itunes,
            session: stubSession(),
            pacing: .concurrent(maxWait: 4)
        )
        #expect(outcome.missedSources == [.itunes])
        #expect(outcome.candidates.isEmpty)
        #expect(RetryStubProtocol.counts.itunes == 0)
        await RequestPacer.itunes.resetForTesting()
    }
}
