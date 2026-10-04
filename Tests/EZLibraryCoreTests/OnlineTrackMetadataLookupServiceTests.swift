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

@Test func titleWithoutArtistStripsALeadingOrTrailingArtist() {
    #expect(OnlineTrackMetadataLookupService.titleWithoutArtist("Justice - D.A.N.C.E.", artist: "Justice") == "D.A.N.C.E.")
    #expect(OnlineTrackMetadataLookupService.titleWithoutArtist("Justice: D.A.N.C.E.", artist: "Justice") == "D.A.N.C.E.")
    // Case-insensitive.
    #expect(OnlineTrackMetadataLookupService.titleWithoutArtist("justice - Song", artist: "Justice") == "Song")
    // Trailing "Song - Artist".
    #expect(OnlineTrackMetadataLookupService.titleWithoutArtist("Sail - AWOLNATION", artist: "AWOLNATION") == "Sail")
}

@Test func titleWithoutArtistLeavesGenuineTitlesAlone() {
    // No separator after the artist word: this is the song's real name.
    #expect(OnlineTrackMetadataLookupService.titleWithoutArtist("Justice For All", artist: "Justice") == "Justice For All")
    // The trailing part is a descriptor, not the artist.
    #expect(OnlineTrackMetadataLookupService.titleWithoutArtist("Sail - Extended Mix", artist: "AWOLNATION") == "Sail - Extended Mix")
    // Empty artist changes nothing.
    #expect(OnlineTrackMetadataLookupService.titleWithoutArtist("Justice - Song", artist: "") == "Justice - Song")
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

@Test func youTubeAPIKeyResolvesFromEnvironmentThenSavedKey() {
    // In-memory defaults and an in-memory credential store: a named suite
    // leaves a plist behind, and the default store is the real keychain.
    let defaults = TestDefaults.inMemory()
    let store = InMemoryCredentialStore()

    // The environment wins when set.
    #expect(OnlineTrackMetadataLookupService.youTubeAPIKey(
        environment: [OnlineTrackMetadataLookupService.youTubeAPIKeyEnvironmentKey: "env-key"],
        userDefaults: defaults,
        credentials: store
    ) == "env-key")

    // Falls back to a value saved in settings.
    OnlineTrackMetadataLookupService.setYouTubeAPIKey("saved-key", userDefaults: defaults, credentials: store)
    #expect(OnlineTrackMetadataLookupService.youTubeAPIKey(
        environment: [:], userDefaults: defaults, credentials: store) == "saved-key")

    // Nothing configured means no YouTube lookups.
    #expect(OnlineTrackMetadataLookupService.youTubeAPIKey(
        environment: [:], userDefaults: TestDefaults.inMemory(), credentials: InMemoryCredentialStore()) == nil)
}

@Test func inferReleaseYearReadsAYearFromText() {
    // A bracketed year is taken as the release year.
    #expect(OnlineTrackMetadataLookupService.inferReleaseYear(fromText: "Artist - Title (2019)") == 2019)
    #expect(OnlineTrackMetadataLookupService.inferReleaseYear(fromText: "Artist - Title [1998]") == 1998)
    // A standalone year works too.
    #expect(OnlineTrackMetadataLookupService.inferReleaseYear(fromText: "2001 - Artist - Title") == 2001)
    // The earliest plausible year when several appear (original over remaster).
    #expect(OnlineTrackMetadataLookupService.inferReleaseYear(fromText: "Title 1999 (2021 Remaster)") == 1999)
    // Nothing plausible: no year, a BPM, or an out-of-range number.
    #expect(OnlineTrackMetadataLookupService.inferReleaseYear(fromText: "Artist - Title") == nil)
    #expect(OnlineTrackMetadataLookupService.inferReleaseYear(fromText: "128 BPM Mix") == nil)
    #expect(OnlineTrackMetadataLookupService.inferReleaseYear(fromText: "Track 3200") == nil)
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

    /// A bulk run holds iTunes to its sustained rate from the first request,
    /// instead of starting at the floor and losing requests to the throttle
    /// while it backs off. An interactive search is still sent at the floor.
    @Test func bulkPacingHoldsITunesToItsSustainedRate() async {
        // Reserving a slot never sleeps, so real intervals cost nothing here.
        RequestPacer.delayScale = 1
        defer { RequestPacer.delayScale = 0 }

        let bulkInterval = OnlineTrackMetadataLookupService.Pacing.bulk.minimumInterval(for: .itunes)
        #expect(bulkInterval >= 3)
        #expect(OnlineTrackMetadataLookupService.Pacing.interactive.minimumInterval(for: .itunes) == 0)
        #expect(OnlineTrackMetadataLookupService.Pacing.bulk.minimumInterval(for: .deezer) == 0)

        let bulk = RequestPacer(floor: 0.25)
        #expect(await bulk.reserveSlot(minimumInterval: bulkInterval) == 0)
        let secondBulk = await bulk.reserveSlot(minimumInterval: bulkInterval)
        #expect(abs(secondBulk - bulkInterval) < 0.1)

        let interactive = RequestPacer(floor: 0.25)
        _ = await interactive.reserveSlot()
        let secondInteractive = await interactive.reserveSlot()
        #expect(abs(secondInteractive - 0.25) < 0.1)
    }

    /// With many tracks in flight, a search skips iTunes rather than queue
    /// behind the others for it. Skipping takes no slot, so the queue stays
    /// as it was for whoever comes next.
    @Test func concurrentPacingSkipsAQueueLongerThanItsLimit() async {
        RequestPacer.delayScale = 1
        defer { RequestPacer.delayScale = 0 }

        let pacing = OnlineTrackMetadataLookupService.Pacing.concurrent(maxWait: 4)
        #expect(pacing.minimumInterval(for: .itunes) == 3)
        #expect(pacing.maxWait(for: .itunes) == 4)
        // Sources with no bulk spacing never queue long, so they always wait.
        #expect(pacing.maxWait(for: .deezer) == nil)
        #expect(OnlineTrackMetadataLookupService.Pacing.bulk.maxWait(for: .itunes) == nil)

        let pacer = RequestPacer(floor: 0.25)
        #expect(await pacer.reserveSlotIfSoon(minimumInterval: 3, maxWait: 4) == 0)
        let second = await pacer.reserveSlotIfSoon(minimumInterval: 3, maxWait: 4)
        #expect(second.map { abs($0 - 3) < 0.1 } == true)
        // Third would wait ~6s: skipped, and the queue is unchanged.
        #expect(await pacer.reserveSlotIfSoon(minimumInterval: 3, maxWait: 4) == nil)
        let afterSkip = await pacer.reserveSlot(minimumInterval: 3)
        #expect(abs(afterSkip - 6) < 0.1)
    }

    /// A skipped source reports `busy` rather than a rate limit: nothing was
    /// sent, and there is nothing for the user to wait out.
    @Test func aSearchThatSkipsITunesSendsNothingToIt() async {
        RequestPacer.delayScale = 1
        defer { RequestPacer.delayScale = 0 }
        // Book the next twelve seconds of the iTunes queue.
        for _ in 0..<4 { _ = await RequestPacer.itunes.reserveSlot(minimumInterval: 3) }
        StubURLProtocol.reset(responses: [(200, itunesHit)])

        do {
            _ = try await OnlineTrackMetadataLookupService.lookup(
                query: .init(title: "Skip Me", artist: "Calvin Harris", album: ""),
                sourceSelection: .itunes,
                session: stubbedSession(),
                pacing: .concurrent(maxWait: 4)
            )
            Issue.record("expected iTunes to be skipped")
        } catch let error as OnlineTrackMetadataLookupService.LookupError {
            guard case .busy(.itunes) = error else {
                Issue.record("unexpected error: \(error)")
                return
            }
            #expect(!error.isRateLimit)
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(StubURLProtocol.totalRequests == 0)
        await RequestPacer.itunes.resetForTesting()
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
            // The random album only defeats the lookup cache. It used to go on
            // the title, which a Wikipedia page now has to match.
            query: .init(title: "Neverender", artist: "Justice", album: UUID().uuidString),
            sourceSelection: .wikipedia,
            session: stubbedSession()
        )

        #expect(results?.first?.source == .wikipedia)
        #expect(results?.first?.album == "Hyperdrama")
        #expect(results?.first?.year == 2024)
    }
}

// MARK: - Wikipedia: the right page, and the album without the date

@Test func wikipediaAlbumStopsAtTheReleaseDate() {
    // Real summary text for "Wake Me Up (Avicii song)". The album came back as
    // "True on 17 June 2013" before the date stop was added.
    let extract = "\"Wake Me Up\" is a song by Swedish DJ and record producer Avicii. It was released as "
        + "the lead single from his debut album True on 17 June 2013, by PRMD Music and Island Records."
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(fromExtract: extract).name == "True")

    let inYear = "It appeared on the band's album Discovery in 2001 and reached number two."
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(fromExtract: inYear).name == "Discovery")

    let inMonth = "It was included on the album Random Access Memories in May 2013."
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(fromExtract: inMonth).name == "Random Access Memories")
}

@Test func anAlbumNamedAfterAMonthIsNotCutShort() {
    // "on"/"in" followed by a month is a date; a title that merely contains a
    // month name, with no "on"/"in" before it, is kept whole.
    let extract = "The song is from their album Hot Summer Nights (2019)."
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(fromExtract: extract).name == "Hot Summer Nights")
}

@Test func onlyWikipediaPagesAboutTheSearchedSongCount() {
    func page(_ title: String) -> WikipediaSearchPage {
        WikipediaSearchPage(key: nil, title: title, description: "2013 single by Avicii", excerpt: nil)
    }
    // What "Levels Avicii" actually returns: both are song pages.
    #expect(OnlineTrackMetadataLookupService.wikipediaPage(page("Levels (Avicii song)"), isAbout: "Levels"))
    #expect(!OnlineTrackMetadataLookupService.wikipediaPage(page("Wake Me Up (Avicii song)"), isAbout: "Levels"))
    // Version wording on the file's title does not stop the match.
    #expect(OnlineTrackMetadataLookupService.wikipediaPage(page("Levels (Avicii song)"), isAbout: "Levels (Original Mix)"))
    #expect(OnlineTrackMetadataLookupService.wikipediaPage(page("D.A.N.C.E."), isAbout: "D.A.N.C.E"))
}

// MARK: - Wikipedia: commas, digits, and EPs

@Test func wikipediaAlbumAfterACommaAndWithACommaInIt() {
    // Real summary text. All three yielded no album before.
    let midnightCity = "It was first released in France on 16 August 2011, as the lead single from the group's "
        + "sixth studio album, Hurry Up, We're Dreaming (2011). The song was written by Anthony Gonzalez."
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(fromExtract: midnightCity).name == "Hurry Up, We're Dreaming")

    let oneMoreTime = "released in November 2000 by Virgin Records as the lead single from their second studio album, Discovery (2001)."
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(fromExtract: oneMoreTime).name == "Discovery")

    let feelSoClose = "released as the second single from his third studio album, 18 Months (2012). In order to have lyrics"
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(fromExtract: feelSoClose).name == "18 Months")
}

@Test func wikipediaAlbumWithCommasDoesNotSwallowAClause() {
    let extract = "from the album Discovery, which was reissued (2001)."
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(fromExtract: extract).name == "Discovery")
}

@Test func wikipediaNamesAnEPWhenThatIsTheSongsHome() {
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(
        fromExtract: "It was released as the title track of his EP Bangarang (2011).").name == "Bangarang")
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(
        fromExtract: "the lead single from her debut extended play, Night Drive (2019).").name == "Night Drive")
    // "Albums Chart" is not an album.
    #expect(OnlineTrackMetadataLookupService.wikipediaAlbum(
        fromExtract: "It reached number two on the UK Albums Chart.").name == "")
}

@Test func wikipediaPrefersTheSongsYearToTheAlbums() {
    let parsed = OnlineTrackMetadataLookupService.parseWikipediaSummary(
        description: "2011 single by Calvin Harris",
        extract: "released as the second single from his third studio album, 18 Months (2012)."
    )
    #expect(parsed.album == "18 Months")
    #expect(parsed.year == 2011)
    // With no year in the description, the album's year is used.
    let noDescription = OnlineTrackMetadataLookupService.parseWikipediaSummary(
        description: "Song by Calvin Harris",
        extract: "released as the second single from his third studio album, 18 Months (2012)."
    )
    #expect(noDescription.year == 2012)
}
