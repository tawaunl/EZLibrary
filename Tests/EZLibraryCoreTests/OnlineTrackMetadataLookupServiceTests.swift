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

// MARK: - Wikipedia and YouTube

@Test func wikipediaSummaryYieldsOriginalAlbumAndYear() {
    let parsed = OnlineTrackMetadataLookupService.parseWikipediaSummary(
        description: "2024 single by Justice",
        extract: "\"Neverender\" is a song by French electronic duo Justice, released on 22 March 2024 as the third single from their fourth studio album Hyperdrama (2024)."
    )
    #expect(parsed.album == "Hyperdrama")
    #expect(parsed.year == 2024)
}

@Test func wikipediaAlbumStopsAtPunctuationAndSentenceWords() {
    let hyperdrama = OnlineTrackMetadataLookupService.wikipediaAlbum(
        fromExtract: "from their fourth studio album Hyperdrama (2024).")
    #expect(hyperdrama.name == "Hyperdrama")
    #expect(hyperdrama.year == 2024)

    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(
        fromExtract: "the lead single from the album Future Nostalgia, released in 2020.").name == "Future Nostalgia")

    // Stops before a sentence continuation rather than swallowing it.
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(
        fromExtract: "from their album Discovery which peaked at number one.").name == "Discovery")

    // A multi-word title is kept whole.
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(
        fromExtract: "on the album Random Access Memories (2013).").name == "Random Access Memories")
}

@Test func wikipediaAlbumDoesNotInventOneFromTheSentence() {
    // No album named — must not capture the sentence as an album.
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(
        fromExtract: "\"Song\" is a 2020 single by an artist.").name == "")
}

@Test func inferGenreFindsGenreInFreeText() {
    #expect(OnlineTrackMetadataLookupService.inferGenre(fromText: "a French electronic duo") == "Electronic")
    #expect(OnlineTrackMetadataLookupService.inferGenre(fromText: "an American hip hop recording") == "Hip Hop")
    // Specific beats general: "deep house" wins over "house".
    #expect(OnlineTrackMetadataLookupService.inferGenre(fromText: "a deep house record") == "Deep House")
}

@Test func inferGenreIsWordBounded() {
    // "rock" must not be found inside "rocky", nor "pop" inside "populist".
    #expect(OnlineTrackMetadataLookupService.inferGenre(fromText: "a rocky mountain populist anthem") == "")
    #expect(OnlineTrackMetadataLookupService.inferGenre(fromText: "nothing musical stated here") == "")
}

@Test func likelySongPageUsesTheOneLineDescription() {
    #expect(OnlineTrackMetadataLookupService.isLikelySongPage(
        WikipediaSearchPage(key: "X", title: "X", description: "2024 single by Y", excerpt: nil)))
    #expect(OnlineTrackMetadataLookupService.isLikelySongPage(
        WikipediaSearchPage(key: "X", title: "X", description: "American singer", excerpt: nil)) == false)
    #expect(OnlineTrackMetadataLookupService.isLikelySongPage(
        WikipediaSearchPage(key: "X", title: "X", description: nil, excerpt: nil)) == false)
}

@Test func youTubeAPIKeyResolvesFromEnvironmentThenDefaults() {
    let defaults = UserDefaults(suiteName: "youtube-key-\(UUID().uuidString)")!

    // The environment wins when set.
    #expect(OnlineTrackMetadataLookupService.youTubeAPIKey(
        environment: [OnlineTrackMetadataLookupService.youTubeAPIKeyEnvironmentKey: "env-key"],
        userDefaults: defaults
    ) == "env-key")

    // Falls back to a value saved in settings.
    defaults.set("saved-key", forKey: OnlineTrackMetadataLookupService.youTubeAPIKeyDefaultsKey)
    #expect(OnlineTrackMetadataLookupService.youTubeAPIKey(
        environment: [:], userDefaults: defaults) == "saved-key")

    // Nothing configured means no YouTube lookups.
    let empty = UserDefaults(suiteName: "youtube-empty-\(UUID().uuidString)")!
    #expect(OnlineTrackMetadataLookupService.youTubeAPIKey(
        environment: [:], userDefaults: empty) == nil)
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
        await RequestPacer.wikipedia.resetForTesting()
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

    /// A Wikipedia lookup searches for the page, then reads the summary and
    /// turns the prose into an album-and-year candidate.
    @Test func wikipediaLookupBuildsAnAlbumCandidate() async {
        let search = Data("""
        {"pages":[{"id":1,"key":"Neverender","title":"Neverender","description":"2024 single by Justice"}]}
        """.utf8)
        let summary = Data("""
        {"title":"Neverender","description":"2024 single by Justice","extract":"\\"Neverender\\" is a song by French electronic duo Justice, released in 2024 as the third single from their fourth studio album Hyperdrama (2024)."}
        """.utf8)
        StubURLProtocol.reset(responses: [(200, search), (200, summary)])

        let results = try? await OnlineTrackMetadataLookupService.lookup(
            query: .init(title: "Neverender \(UUID().uuidString)", artist: "Justice", album: ""),
            sourceSelection: .wikipedia,
            session: stubbedSession()
        )

        #expect(results?.first?.source == .wikipedia)
        #expect(results?.first?.album == "Hyperdrama")
        #expect(results?.first?.year == 2024)
    }
}
