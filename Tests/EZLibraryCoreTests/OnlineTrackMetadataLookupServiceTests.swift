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
@testable import EZLibraryCore

@Test func searchableTermStripsTrailingDescriptors() {
    #expect(OnlineTrackMetadataLookupService.searchableTerm("Song Name (Intro)") == "Song Name")
    #expect(OnlineTrackMetadataLookupService.searchableTerm("Song Name (X) (Live)") == "Song Name")
    #expect(OnlineTrackMetadataLookupService.searchableTerm("Song Name [Intro]") == "Song Name")
    #expect(OnlineTrackMetadataLookupService.searchableTerm("Song Name") == "Song Name")
    #expect(OnlineTrackMetadataLookupService.searchableTerm("  Song Name (etc.)  ") == "Song Name")
}

@Test func titlePreservesDJDescriptorsFromOriginal() {
    // A store match (plain title) re-attaches the original's DJ descriptor.
    #expect(
        OnlineTrackMetadataLookupService.titlePreservingDescriptors(from: "Feel So Close", original: "Feel So Close (Intro)")
            == "Feel So Close (Intro)"
    )
    #expect(
        OnlineTrackMetadataLookupService.titlePreservingDescriptors(from: "Closer", original: "Closer [Clean]")
            == "Closer [Clean]"
    )
    // Multiple DJ descriptors are all preserved, in order.
    #expect(
        OnlineTrackMetadataLookupService.titlePreservingDescriptors(from: "Levels", original: "Levels (Extended) (Dirty)")
            == "Levels (Extended) (Dirty)"
    )
}

@Test func titlePreserveIgnoresNonDJParentheticals() {
    // Featured-artist / non-DJ parentheticals are not re-attached.
    #expect(
        OnlineTrackMetadataLookupService.titlePreservingDescriptors(from: "Stay", original: "Stay (feat. Justin Bieber)")
            == "Stay"
    )
    #expect(
        OnlineTrackMetadataLookupService.titlePreservingDescriptors(from: "Title", original: "Title (2019 Remaster)")
            == "Title"
    )
}

@Test func titlePreserveDoesNotDuplicateExistingDescriptor() {
    // The candidate already carries the descriptor — don't duplicate it.
    #expect(
        OnlineTrackMetadataLookupService.titlePreservingDescriptors(from: "Song (Intro)", original: "Song (Intro)")
            == "Song (Intro)"
    )
    #expect(
        OnlineTrackMetadataLookupService.titlePreservingDescriptors(from: "Song (Clean Edit)", original: "Song (Clean)")
            == "Song (Clean Edit)"
    )
}

// MARK: - Throttling and caching

import Foundation

/// Serves canned responses so the lookup tests never touch the network.
private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    /// Status code + body returned for each successive request.
    nonisolated(unsafe) static var responses: [(status: Int, body: Data)] = []
    nonisolated(unsafe) static var requestCount = 0
    private static let lock = NSLock()

    static func reset(responses: [(status: Int, body: Data)]) {
        lock.lock()
        defer { lock.unlock() }
        self.responses = responses
        requestCount = 0
    }

    static func next() -> (status: Int, body: Data) {
        lock.lock()
        defer { lock.unlock() }
        let response = requestCount < responses.count ? responses[requestCount] : (200, Data("{}".utf8))
        requestCount += 1
        return response
    }

    static var totalRequests: Int {
        lock.lock()
        defer { lock.unlock() }
        return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        let (status, body) = Self.next()
        let response = HTTPURLResponse(
            url: request.url!,
            statusCode: status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Retry-After": "0"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func stubbedSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

private let itunesHit = Data("""
{"resultCount":1,"results":[{"trackName":"Feel So Close","artistName":"Calvin Harris","collectionName":"18 Months","primaryGenreName":"Dance","releaseDate":"2012-10-26","artworkUrl100":"https://example.invalid/100x100bb.jpg"}]}
""".utf8)

/// These share `StubURLProtocol`'s canned-response state, so they run one
/// at a time rather than concurrently.
@Suite(.serialized) struct OnlineLookupNetworkTests {
    /// Runs the retry/backoff paths without sleeping through the real intervals.
    init() async {
        RequestPacer.delayScale = 0
        await RequestPacer.itunes.resetForTesting()
        await RequestPacer.musicBrainz.resetForTesting()
        await RequestPacer.discogs.resetForTesting()
    }

    /// A throttled iTunes reply is a 403 with an empty body. That used to fail the
    /// JSON decode and surface as "no matches found", which reads as a track that
    /// isn't in the store rather than a rate limit the user can wait out.
    @Test func throttledITunesResponseSurfacesAsRateLimit() async {
        StubURLProtocol.reset(responses: Array(repeating: (403, Data()), count: 10))

        await #expect(throws: OnlineTrackMetadataLookupService.LookupError.self) {
            try await OnlineTrackMetadataLookupService.lookup(
                query: .init(title: "Feel So Close", artist: "Calvin Harris", album: ""),
                sourceSelection: .itunes,
                session: stubbedSession()
            )
        }

        do {
            _ = try await OnlineTrackMetadataLookupService.lookup(
                query: .init(title: "Feel So Close 2", artist: "Calvin Harris", album: ""),
                sourceSelection: .itunes,
                session: stubbedSession()
            )
            Issue.record("expected a rate limit error")
        } catch let error as OnlineTrackMetadataLookupService.LookupError {
            #expect(error.isRateLimit)
            #expect(error.errorDescription?.contains("rate limiting") == true)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
    }

    /// A throttled request is retried rather than given up on after one attempt.
    @Test func throttledRequestIsRetriedBeforeFailing() async {
        StubURLProtocol.reset(responses: [(429, Data()), (429, Data()), (200, itunesHit)])

        let results = try? await OnlineTrackMetadataLookupService.lookup(
            query: .init(title: "Retry Me", artist: "Calvin Harris", album: ""),
            sourceSelection: .itunes,
            session: stubbedSession()
        )

        #expect(results?.count == 1)
        #expect(StubURLProtocol.totalRequests == 3)
    }

    /// The lookup cache must only hold hits. Caching an empty result meant one
    /// throttled or interrupted search kept answering "no matches" from memory for
    /// five minutes, so pressing Search Online again appeared to do nothing.
    @Test func emptyResultIsNotCached() async {
        // Unique terms so this test can't collide with another test's cache entry.
        let query = OnlineTrackMetadataLookupService.Query(
            title: "Uncached \(UUID().uuidString)", artist: "Nobody", album: ""
        )

        // First search fails outright.
        StubURLProtocol.reset(responses: Array(repeating: (403, Data()), count: 10))
        _ = try? await OnlineTrackMetadataLookupService.lookup(
            query: query, sourceSelection: .itunes, session: stubbedSession()
        )

        // The retry must hit the network again instead of replaying the empty result.
        StubURLProtocol.reset(responses: [(200, itunesHit)])
        let results = try? await OnlineTrackMetadataLookupService.lookup(
            query: query, sourceSelection: .itunes, session: stubbedSession()
        )

        #expect(StubURLProtocol.totalRequests > 0)
        #expect(results?.count == 1)
        #expect(results?.first?.title == "Feel So Close")
    }

    /// Successful results are still cached, so re-running the same search doesn't
    /// re-hit the network.
    @Test func successfulResultIsCached() async {
        let query = OnlineTrackMetadataLookupService.Query(
            title: "Cached \(UUID().uuidString)", artist: "Calvin Harris", album: ""
        )

        StubURLProtocol.reset(responses: [(200, itunesHit)])
        let first = try? await OnlineTrackMetadataLookupService.lookup(
            query: query, sourceSelection: .itunes, session: stubbedSession()
        )
        #expect(first?.count == 1)

        StubURLProtocol.reset(responses: [(500, Data())])
        let second = try? await OnlineTrackMetadataLookupService.lookup(
            query: query, sourceSelection: .itunes, session: stubbedSession()
        )
        #expect(second?.count == 1)
        #expect(StubURLProtocol.totalRequests == 0)
    }
}
