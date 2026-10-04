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

private func filledTrack(genre: String = "Electro") -> Track {
    Track(
        seratoStoredPath: "Music/Justice - Neverender.mp3",
        fileURL: URL(fileURLWithPath: "/nonexistent/Justice - Neverender.mp3"),
        title: "Neverender",
        artist: "Justice",
        album: "Hyperdrama",
        genre: genre,
        comment: "",
        year: 2024
    )
}

/// A verdict JSON body: every field "correct" at `confidence`, except the
/// overrides.
private func verdictJSON(
    identity: Double = 0.95,
    confidence: Double = 0.95,
    overrides: [String: (verdict: String, value: String, confidence: Double)] = [:]
) -> String {
    let fields = AITagVerificationService.verifiableFields.map { field -> String in
        let entry = overrides[field.rawValue] ?? ("correct", "", confidence)
        return """
        {"field":"\(field.rawValue)","verdict":"\(entry.verdict)","proposed_value":"\(entry.value)",\
        "confidence":\(entry.confidence),"evidence":"test","source_url":""}
        """
    }
    return """
    {"identity_confidence":\(identity),"identity_summary":"Justice — Neverender",\
    "fields":[\(fields.joined(separator: ","))]}
    """
}

private func verification(_ json: String, track: Track) throws -> AITagVerificationService.TrackVerification {
    try AITagVerificationService.parse(
        text: json,
        for: track,
        provenance: AITagVerificationService.Provenance(engineLabel: "test")
    )
}

// MARK: - Deciding when to search

@Test func aConfidentCompleteFirstPassNeedsNoSearch() throws {
    let result = try verification(verdictJSON(), track: filledTrack())
    #expect(AITagVerificationService.unsettledFields(in: result).isEmpty)
}

@Test func exactlyEightyPercentIsNotConfidentEnough() throws {
    let result = try verification(
        verdictJSON(overrides: ["year": ("correct", "", 0.8)]),
        track: filledTrack()
    )
    #expect(AITagVerificationService.unsettledFields(in: result) == [.year])
}

@Test func anEmptyFieldLeftEmptyIsUnsettledHoweverSureTheModelIs() throws {
    let track = filledTrack(genre: "")
    let unfilled = try verification(
        verdictJSON(overrides: ["genre": ("unverified", "", 0.95)]),
        track: track
    )
    #expect(AITagVerificationService.unsettledFields(in: unfilled) == [.genre])

    let filled = try verification(
        verdictJSON(overrides: ["genre": ("incorrect", "French House", 0.9)]),
        track: track
    )
    #expect(AITagVerificationService.unsettledFields(in: filled).isEmpty)
}

@Test func aFieldTheModelSkippedIsUnsettled() throws {
    let json = """
    {"identity_confidence":0.95,"identity_summary":"x","fields":[\
    {"field":"title","verdict":"correct","proposed_value":"","confidence":0.95,"evidence":"","source_url":""}]}
    """
    let result = try verification(json, track: filledTrack())
    #expect(AITagVerificationService.unsettledFields(in: result) == [.artist, .album, .genre, .year])
}

@Test func theCostQuoteAssumesEveryTrackNeedsBothPasses() {
    var options = AITagVerificationService.Options(model: .sonnet55)
    options.useWebSearch = false
    let firstPassOnly = AITagVerificationService.estimatedCost(trackCount: 100, options: options)
    options.useWebSearch = true
    let ceiling = AITagVerificationService.estimatedCost(trackCount: 100, options: options)

    // 100 × (2,600 × $2 + 1,220 × $10) / 1M for the first pass, plus the
    // searching pass and its 1.7 searches a track at a cent each.
    #expect(abs(firstPassOnly - 1.74) < 0.001)
    #expect(abs(ceiling - (1.74 + 7.44 + 1.70)) < 0.001)
}

// MARK: - The two passes on the wire

/// Records each request body and answers with the next canned Claude reply.
private final class ClaudeStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var replies: [String] = []
    nonisolated(unsafe) static var bodies: [[String: Any]] = []
    private static let lock = NSLock()

    static func reset(replies: [String]) {
        lock.lock()
        defer { lock.unlock() }
        self.replies = replies
        bodies = []
    }

    static var recordedBodies: [[String: Any]] {
        lock.lock()
        defer { lock.unlock() }
        return bodies
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let body = Self.readBody(of: request)
        Self.lock.lock()
        Self.bodies.append(body)
        let index = Self.bodies.count - 1
        let text = index < Self.replies.count ? Self.replies[index] : "{}"
        Self.lock.unlock()

        let payload: [String: Any] = [
            "content": [["type": "text", "text": text]],
            "stop_reason": "end_turn",
            "usage": ["input_tokens": 1000, "output_tokens": 100]
        ]
        let data = (try? JSONSerialization.data(withJSONObject: payload)) ?? Data()
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }

    /// URLSession hands a protocol the body as a stream, not `httpBody`.
    private static func readBody(of request: URLRequest) -> [String: Any] {
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
        return ((try? JSONSerialization.jsonObject(with: data)) as? [String: Any]) ?? [:]
    }
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ClaudeStubProtocol.self]
    return URLSession(configuration: configuration)
}

private let offlineOptions = AITagVerificationService.Options(
    model: .sonnet55,
    useWebSearch: true,
    useFingerprint: false,
    useOnlineCandidates: false
)

private func userMessage(of body: [String: Any]) -> String {
    ((body["messages"] as? [[String: Any]])?.first?["content"] as? String) ?? ""
}

/// These share `ClaudeStubProtocol`'s state, so they run one at a time.
@Suite(.serialized)
struct SearchEscalationWireTests {
    @Test func aConfidentFirstPassIsTheOnlyRequestAndDoesNotSearch() async throws {
        ClaudeStubProtocol.reset(replies: [verdictJSON()])

        let result = try await AITagVerificationService.verify(
            track: filledTrack(),
            options: offlineOptions,
            apiKey: "sk-test",
            session: stubbedSession()
        )

        let bodies = ClaudeStubProtocol.recordedBodies
        #expect(bodies.count == 1)
        #expect(bodies.first?["tools"] == nil)
        #expect(userMessage(of: bodies[0]).contains("WEB SEARCH: not available on this pass"))
        #expect(result.usage == TagVerificationUsage(inputTokens: 1000, outputTokens: 100))
    }

    @Test func anUnsureFirstPassGoesRoundAgainWithSearch() async throws {
        let track = filledTrack(genre: "")
        ClaudeStubProtocol.reset(replies: [
            verdictJSON(overrides: [
                "genre": ("unverified", "", 0.9),
                "year": ("correct", "", 0.6)
            ]),
            verdictJSON(overrides: ["genre": ("incorrect", "French House", 0.9)])
        ])

        let result = try await AITagVerificationService.verify(
            track: track,
            options: offlineOptions,
            apiKey: "sk-test",
            session: stubbedSession()
        )

        let bodies = ClaudeStubProtocol.recordedBodies
        try #require(bodies.count == 2)
        #expect(bodies[0]["tools"] == nil)
        let tools = bodies[1]["tools"] as? [[String: Any]]
        #expect(tools?.first?["name"] as? String == "web_search")
        #expect(userMessage(of: bodies[1]).contains("WAS NOT SURE OF: genre, year"))
        #expect(!userMessage(of: bodies[1]).contains("not available on this pass"))

        // The searching pass's answer is the one returned, and the bill covers both.
        #expect(result.fields.first { $0.field == .genre }?.proposedValue == "French House")
        #expect(result.usage == TagVerificationUsage(inputTokens: 2000, outputTokens: 200))
    }

    @Test func anUnsureIdentityAloneTriggersTheSearch() async throws {
        ClaudeStubProtocol.reset(replies: [verdictJSON(identity: 0.5), verdictJSON()])

        _ = try await AITagVerificationService.verify(
            track: filledTrack(),
            options: offlineOptions,
            apiKey: "sk-test",
            session: stubbedSession()
        )

        let bodies = ClaudeStubProtocol.recordedBodies
        try #require(bodies.count == 2)
        #expect(userMessage(of: bodies[1]).contains("NOT SURE OF: which recording this is"))
    }

    @Test func withSearchOffThereIsOnePassAndNoPromiseOfASecond() async throws {
        ClaudeStubProtocol.reset(replies: [verdictJSON(confidence: 0.4)])
        var options = offlineOptions
        options.useWebSearch = false

        _ = try await AITagVerificationService.verify(
            track: filledTrack(),
            options: options,
            apiKey: "sk-test",
            session: stubbedSession()
        )

        let bodies = ClaudeStubProtocol.recordedBodies
        #expect(bodies.count == 1)
        #expect(!userMessage(of: bodies[0]).contains("WEB SEARCH"))
    }
}
