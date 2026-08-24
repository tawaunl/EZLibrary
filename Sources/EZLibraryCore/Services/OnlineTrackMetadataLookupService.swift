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

public enum OnlineMetadataSource: String, CaseIterable, Sendable {
    case itunes
    case musicBrainz
    case deezer
    case discogs
    /// Free, keyless, and the best of the sources at naming the *original*
    /// album a song first appeared on — the catalog APIs routinely return the
    /// single or a compilation instead. The consensus engine gives it the last
    /// word on the album field for exactly that reason.
    case wikipedia
    /// A last resort for genre only, and the one source that costs quota: it
    /// needs a YouTube Data API key supplied at runtime and returns nothing
    /// without one. Never included in the free/fast sets.
    case youTube

    public var displayName: String {
        switch self {
        case .itunes:
            return "iTunes"
        case .musicBrainz:
            return "MusicBrainz"
        case .deezer:
            return "Deezer"
        case .discogs:
            return "Discogs"
        case .wikipedia:
            return "Wikipedia"
        case .youTube:
            return "YouTube"
        }
    }

    /// True when the source works with no credential at all. The consensus
    /// verifier leans on these because they are the ones every user has.
    public var requiresCredential: Bool {
        switch self {
        case .itunes, .musicBrainz, .deezer, .wikipedia:
            return false
        case .discogs, .youTube:
            return true
        }
    }
}

public struct OnlineTrackMetadataCandidate: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let source: OnlineMetadataSource
    public let title: String
    public let artist: String
    public let album: String
    public let genre: String
    public let year: Int?
    public let bpm: Double?
    public let comment: String
    /// URL to downloadable cover art for this candidate, when available.
    public let artworkURL: URL?
    /// Track length in seconds, when the source reports it.
    ///
    /// This is the cheapest way to tell two recordings of the same song apart:
    /// a radio edit and an extended mix share a title and differ by minutes.
    /// The consensus verifier uses it to reject candidates that cannot be the
    /// file it is looking at.
    public let durationSeconds: Double?

    public init(
        id: UUID = UUID(),
        source: OnlineMetadataSource,
        title: String,
        artist: String,
        album: String,
        genre: String,
        year: Int?,
        bpm: Double?,
        comment: String = "",
        artworkURL: URL? = nil,
        durationSeconds: Double? = nil
    ) {
        self.id = id
        self.source = source
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.year = year
        self.bpm = bpm
        self.comment = comment
        self.artworkURL = artworkURL
        self.durationSeconds = durationSeconds
    }
}

/// Caches recent lookup results in memory so re-running the same search
/// (e.g. after a small edit to the search terms) doesn't re-hit the network.
private actor OnlineMetadataLookupCache {
    static let shared = OnlineMetadataLookupCache()

    private struct Entry {
        let timestamp: Date
        let results: [OnlineTrackMetadataCandidate]
    }

    private var storage: [String: Entry] = [:]
    private let ttl: TimeInterval = 300
    private let maxEntries = 200

    func get(_ key: String) -> [OnlineTrackMetadataCandidate]? {
        guard let entry = storage[key] else { return nil }
        guard Date().timeIntervalSince(entry.timestamp) <= ttl else {
            storage.removeValue(forKey: key)
            return nil
        }
        return entry.results
    }

    func set(_ key: String, results: [OnlineTrackMetadataCandidate]) {
        if storage.count >= maxEntries {
            storage.removeAll()
        }
        storage[key] = Entry(timestamp: Date(), results: results)
    }
}

/// Paces outbound requests to a single source and backs off when that source
/// starts throttling us.
///
/// The iTunes Search API is undocumented about its exact budget but starts
/// answering with an empty-bodied 403/429 after roughly 20-60 requests a
/// minute. The bulk tag actions blow through that in seconds, so without
/// pacing a bulk run fails nearly every lookup. The interval adapts: it doubles
/// on each throttled response and relaxes back toward the floor as requests
/// succeed, so a single lookup stays fast while a long bulk run settles at
/// whatever rate the source actually allows.
actor RequestPacer {
    static let itunes = RequestPacer(floor: 0.25)
    /// MusicBrainz documents a hard 1 request/second limit.
    static let musicBrainz = RequestPacer(floor: 1.0)
    /// Discogs allows 60 authenticated requests a minute.
    static let discogs = RequestPacer(floor: 1.0)
    /// Deezer's public catalog allows roughly 50 requests per 5 seconds.
    static let deezer = RequestPacer(floor: 0.1)
    /// Wikipedia sets no hard published rate limit for these read endpoints, so
    /// this floor is politeness rather than a documented ceiling.
    static let wikipedia = RequestPacer(floor: 0.1)
    /// YouTube's limit is a daily quota, not a per-second rate, so this only
    /// keeps a burst civil.
    static let youTube = RequestPacer(floor: 0.1)

    /// Scales every wait this pacer hands out. Tests set it to 0 so they exercise
    /// the retry and backoff logic without sleeping through the real intervals.
    nonisolated(unsafe) static var delayScale: Double = 1.0

    private let floor: TimeInterval
    private let ceiling: TimeInterval = 8.0
    private var interval: TimeInterval
    private var nextSlot = Date.distantPast

    init(floor: TimeInterval) {
        self.floor = floor
        self.interval = floor
    }

    /// Clears the adaptive state so one test's backoff doesn't slow the next.
    func resetForTesting() {
        interval = floor
        nextSlot = .distantPast
    }

    /// Claims the next send slot and returns how long the caller must wait
    /// before sending. The caller sleeps outside the actor so reserving a slot
    /// never blocks other callers.
    func reserveSlot() -> TimeInterval {
        let now = Date()
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(interval)
        return slot.timeIntervalSince(now) * Self.delayScale
    }

    func recordThrottled(retryAfter: TimeInterval?) {
        interval = min(ceiling, max(interval * 2, floor))
        // Honor Retry-After when the source sends one, but never let a stray
        // large value stall the queue past the ceiling.
        let cooldown = min(retryAfter ?? interval, ceiling) * Self.delayScale
        nextSlot = max(nextSlot, Date().addingTimeInterval(cooldown))
    }

    func recordSuccess() {
        interval = max(floor, interval * 0.8)
    }
}

public enum OnlineTrackMetadataLookupService {
    public static let discogsTokenEnvironmentKey = "EZLIBRARY_DISCOGS_TOKEN"
    /// Legacy environment key, still honored for backward compatibility.
    public static let legacyDiscogsTokenEnvironmentKey = "SERATOTOOLS_DISCOGS_TOKEN"
    public static let discogsTokenDefaultsKey = "SeratoToolsDiscogsToken"

    /// The YouTube Data API key is read at runtime and never bundled: YouTube
    /// is the only source that costs quota, so it stays opt-in. Supply it in
    /// the environment or in settings; with none present the YouTube source
    /// simply returns nothing.
    public static let youTubeAPIKeyEnvironmentKey = "EZLIBRARY_YOUTUBE_API_KEY"
    /// Legacy environment key, still honored for backward compatibility.
    public static let legacyYouTubeAPIKeyEnvironmentKey = "SERATOTOOLS_YOUTUBE_API_KEY"
    public static let youTubeAPIKeyDefaultsKey = "SeratoToolsYouTubeAPIKey"

    /// The User-Agent Wikimedia's policy asks callers to send so a runaway
    /// client can be identified and contacted rather than simply blocked.
    static let wikipediaUserAgent = "EZLibrary/1.0 (https://github.com/tawaunl/EZLibrary; metadata lookup)"

    /// A session with a much shorter timeout than `.shared`'s 60s default, so a
    /// stalled source (MusicBrainz in particular) fails fast instead of stalling
    /// the whole search.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    public enum SourceSelection: String, CaseIterable, Sendable {
        case all
        case itunes
        case musicBrainz
        case deezer
        case discogs
        case wikipedia
        case youTube
        /// Every source that needs no credential — what a user with no keys
        /// configured can actually reach.
        case freeSources
        /// iTunes and Deezer only: the two sources that answer in about a
        /// quarter of a second each. MusicBrainz is excluded because it paces
        /// callers to one request a second and its search latency ranges from
        /// under a second to well past the request timeout, which makes it the
        /// throughput ceiling for a whole-library run.
        case fastSources
        /// The fast pair plus Wikipedia. This is the consensus default: the two
        /// quick catalog sources for title/artist/duration, and Wikipedia for
        /// the original album it names more reliably than either. Wikipedia
        /// costs a request or two more per track than the fast pair alone, but
        /// it is not rate limited, so it does not lower the run's ceiling.
        case recommended

        public var displayName: String {
            switch self {
            case .all:
                return "All Sources"
            case .itunes:
                return "iTunes"
            case .musicBrainz:
                return "MusicBrainz"
            case .deezer:
                return "Deezer"
            case .discogs:
                return "Discogs"
            case .wikipedia:
                return "Wikipedia"
            case .youTube:
                return "YouTube"
            case .freeSources:
                return "Free Sources"
            case .fastSources:
                return "Fast Sources"
            case .recommended:
                return "Recommended (adds Wikipedia)"
            }
        }

        var enabledSources: [OnlineMetadataSource] {
            switch self {
            case .all:
                return OnlineMetadataSource.allCases
            case .itunes:
                return [.itunes]
            case .musicBrainz:
                return [.musicBrainz]
            case .deezer:
                return [.deezer]
            case .discogs:
                return [.discogs]
            case .wikipedia:
                return [.wikipedia]
            case .youTube:
                return [.youTube]
            case .freeSources:
                return OnlineMetadataSource.allCases.filter { !$0.requiresCredential }
            case .fastSources:
                return [.itunes, .deezer]
            case .recommended:
                return [.itunes, .deezer, .wikipedia]
            }
        }

        /// True when this selection fans out across several sources and so
        /// needs the concurrent path.
        var isMultiSource: Bool {
            enabledSources.count > 1
        }
    }

    public struct Query: Sendable {
        public let title: String
        public let artist: String
        public let album: String

        public init(title: String, artist: String, album: String) {
            self.title = title
            self.artist = artist
            self.album = album
        }
    }

    public enum LookupError: LocalizedError {
        case missingSearchTerms
        case missingDiscogsToken
        case missingYouTubeKey
        case sourceRequestFailed(OnlineMetadataSource, String)
        case rateLimited(OnlineMetadataSource)

        public var errorDescription: String? {
            switch self {
            case .missingSearchTerms:
                return "Enter at least a title, artist, or album before searching online."
            case .missingDiscogsToken:
                return "Discogs lookup requires an API token. Set EZLIBRARY_DISCOGS_TOKEN or save a Discogs token in the app settings."
            case .missingYouTubeKey:
                return "YouTube lookup requires a YouTube Data API key. Set EZLIBRARY_YOUTUBE_API_KEY or save a YouTube API key in the app settings."
            case let .sourceRequestFailed(source, message):
                return "\(source.displayName) lookup failed: \(message)"
            case let .rateLimited(source):
                return "\(source.displayName) is rate limiting requests right now. Wait a minute and try again, or look up fewer tracks at a time."
            }
        }

        /// True when the failure is a throttle the user can simply wait out.
        public var isRateLimit: Bool {
            if case .rateLimited = self { return true }
            return false
        }
    }

    /// Status codes that mean "you are asking too often" for a given source.
    /// iTunes answers a throttled search with a 403, where the same code from
    /// Discogs means the token is bad and retrying would not help.
    private static func throttleStatuses(for source: OnlineMetadataSource) -> Set<Int> {
        switch source {
        case .itunes:
            return [403, 429, 503]
        case .musicBrainz, .discogs, .deezer, .wikipedia, .youTube:
            // YouTube's 403 means the daily quota is spent, not that we asked
            // too fast, so it is deliberately not retried here.
            return [429, 503]
        }
    }

    /// Sends a request through the source's pacer, checks the HTTP status, and
    /// retries throttled responses with backoff.
    ///
    /// Checking the status matters more than it looks: a throttled iTunes reply
    /// is a 403 with a zero-byte body, so without this the JSON decode failed
    /// and the empty result was reported as "no matches found" rather than as
    /// the rate limit it actually was.
    private static func performRequest(
        _ request: URLRequest,
        source: OnlineMetadataSource,
        pacer: RequestPacer,
        session: URLSession,
        maxAttempts: Int = 3,
        errorMessage: (@Sendable (Data) -> String?)? = nil
    ) async throws -> Data {
        var lastThrottle: LookupError?

        for attempt in 1...maxAttempts {
            let delay = await pacer.reserveSlot()
            if delay > 0 {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            }

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }

            switch http.statusCode {
            case 200...299:
                await pacer.recordSuccess()
                return data
            case let code where throttleStatuses(for: source).contains(code):
                let retryAfter = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
                await pacer.recordThrottled(retryAfter: retryAfter)
                lastThrottle = .rateLimited(source)
                if attempt == maxAttempts { throw LookupError.rateLimited(source) }
            default:
                let detail = errorMessage?(data) ?? "HTTP \(http.statusCode)"
                throw LookupError.sourceRequestFailed(source, detail)
            }
        }

        throw lastThrottle ?? .rateLimited(source)
    }

    /// - Parameter deduplicate: Collapses candidates that describe the same
    ///   release into one, which is right for a picker the user chooses from
    ///   and wrong for anything counting corroboration. Two sources
    ///   independently returning the same album *is the signal*, and folding
    ///   them together makes agreement look like a single opinion. Consensus
    ///   verification passes `false`.
    public static func lookup(
        query: Query,
        sourceSelection: SourceSelection = .all,
        maxResultsPerSource: Int = 8,
        session: URLSession = defaultSession,
        deduplicate: Bool = true
    ) async throws -> [OnlineTrackMetadataCandidate] {
        let normalized = normalize(query: query)
        guard !normalized.title.isEmpty || !normalized.artist.isEmpty || !normalized.album.isEmpty else {
            throw LookupError.missingSearchTerms
        }

        let cacheKey = cacheKey(
            for: normalized,
            sourceSelection: sourceSelection,
            deduplicate: deduplicate
        )
        if let cached = await OnlineMetadataLookupCache.shared.get(cacheKey) {
            return cached
        }

        let result: [OnlineTrackMetadataCandidate]
        // Only a run where every source answered is worth caching: caching a
        // partial result would keep serving the sources that happened to
        // succeed for the next five minutes.
        var isComplete = true
        if sourceSelection.isMultiSource {
            let token = discogsToken()
            let outcomes = await withTaskGroup(of: Result<[OnlineTrackMetadataCandidate], Error>.self) { group in
                for source in sourceSelection.enabledSources {
                    group.addTask {
                        do {
                            return .success(try await fetchCandidates(
                                from: source,
                                query: normalized,
                                maxResults: maxResultsPerSource,
                                session: session,
                                discogsToken: token,
                                sourceSelection: sourceSelection
                            ))
                        } catch {
                            return .failure(error)
                        }
                    }
                }

                var all: [Result<[OnlineTrackMetadataCandidate], Error>] = []
                for await outcome in group {
                    all.append(outcome)
                }
                return all
            }

            let combined = outcomes.flatMap { (try? $0.get()) ?? [] }
            isComplete = primaryFailure(in: outcomes) == nil
            // A source failing while another returns matches is not worth
            // surfacing, but every source failing must not look like "no
            // matches found" — that reads as a missing track rather than as
            // the rate limit or outage it usually is.
            if combined.isEmpty, let failure = primaryFailure(in: outcomes) {
                throw failure
            }

            result = deduplicate ? deduplicated(candidates: combined) : combined
        } else {
            let results = try await fetchCandidates(
                from: sourceSelection.enabledSources[0],
                query: normalized,
                maxResults: maxResultsPerSource,
                session: session,
                discogsToken: discogsToken(),
                sourceSelection: sourceSelection
            )

            result = deduplicate ? deduplicated(candidates: results) : results
        }

        // Only cache hits. Caching an empty result meant one throttled or
        // interrupted search kept answering "no matches" from memory for the
        // next five minutes, so retrying appeared to do nothing.
        if !result.isEmpty, isComplete {
            await OnlineMetadataLookupCache.shared.set(cacheKey, results: result)
        }
        return result
    }

    /// Picks the most useful error to report when every source failed,
    /// preferring a rate limit since that is the one the user can act on.
    private static func primaryFailure(
        in outcomes: [Result<[OnlineTrackMetadataCandidate], Error>]
    ) -> Error? {
        let errors = outcomes.compactMap { outcome -> Error? in
            if case let .failure(error) = outcome { return error }
            return nil
        }

        if let throttled = errors.first(where: { ($0 as? LookupError)?.isRateLimit == true }) {
            return throttled
        }
        return errors.first
    }

    /// Same lookup as `lookup(query:sourceSelection:maxResultsPerSource:session:)`,
    /// but yields the deduplicated results-so-far as each source responds instead
    /// of waiting for every source in the selection to finish. For `.all`, this
    /// means iTunes results (typically the fastest source) usually appear well
    /// before MusicBrainz/Discogs land.
    public static func lookupStream(
        query: Query,
        sourceSelection: SourceSelection = .all,
        maxResultsPerSource: Int = 8,
        session: URLSession = defaultSession
    ) -> AsyncThrowingStream<[OnlineTrackMetadataCandidate], Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                let normalized = normalize(query: query)
                guard !normalized.title.isEmpty || !normalized.artist.isEmpty || !normalized.album.isEmpty else {
                    continuation.finish(throwing: LookupError.missingSearchTerms)
                    return
                }

                let cacheKey = cacheKey(for: normalized, sourceSelection: sourceSelection)
                if let cached = await OnlineMetadataLookupCache.shared.get(cacheKey) {
                    continuation.yield(cached)
                    continuation.finish()
                    return
                }

                guard sourceSelection.isMultiSource else {
                    do {
                        let results = try await fetchCandidates(
                            from: sourceSelection.enabledSources[0],
                            query: normalized,
                            maxResults: maxResultsPerSource,
                            session: session,
                            discogsToken: discogsToken(),
                            sourceSelection: sourceSelection
                        )
                        let deduped = deduplicated(candidates: results)
                        if !deduped.isEmpty {
                            await OnlineMetadataLookupCache.shared.set(cacheKey, results: deduped)
                        }
                        continuation.yield(deduped)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                let token = discogsToken()
                var accumulated: [OnlineTrackMetadataCandidate] = []
                var failures: [Result<[OnlineTrackMetadataCandidate], Error>] = []
                await withTaskGroup(of: Result<[OnlineTrackMetadataCandidate], Error>.self) { group in
                    for source in sourceSelection.enabledSources {
                        group.addTask {
                            do {
                                return .success(try await fetchCandidates(
                                    from: source,
                                    query: normalized,
                                    maxResults: maxResultsPerSource,
                                    session: session,
                                    discogsToken: token,
                                    sourceSelection: sourceSelection
                                ))
                            } catch {
                                return .failure(error)
                            }
                        }
                    }

                    for await outcome in group {
                        failures.append(outcome)
                        guard let sourceResults = try? outcome.get(), !sourceResults.isEmpty else { continue }
                        accumulated.append(contentsOf: sourceResults)
                        continuation.yield(deduplicated(candidates: accumulated))
                    }
                }

                // Cancellation (the user closing the sheet or starting a new
                // search) must not write the partial results it got so far into
                // the cache, or the next search for this track serves them.
                guard !Task.isCancelled else {
                    continuation.finish()
                    return
                }

                let failure = primaryFailure(in: failures)
                if accumulated.isEmpty, let failure {
                    continuation.finish(throwing: failure)
                    return
                }

                // As above: a partial result (say iTunes throttled but
                // MusicBrainz answered) must not be cached as if it were the
                // full answer.
                if !accumulated.isEmpty, failure == nil {
                    await OnlineMetadataLookupCache.shared.set(cacheKey, results: deduplicated(candidates: accumulated))
                }
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func cacheKey(
        for query: Query,
        sourceSelection: SourceSelection,
        deduplicate: Bool = true
    ) -> String {
        [
            sourceSelection.rawValue,
            deduplicate ? "dedup" : "raw",
            query.title.lowercased(),
            query.artist.lowercased(),
            query.album.lowercased()
        ].joined(separator: "||")
    }

    private static func fetchCandidates(
        from source: OnlineMetadataSource,
        query: Query,
        maxResults: Int,
        session: URLSession,
        discogsToken: String?,
        sourceSelection: SourceSelection
    ) async throws -> [OnlineTrackMetadataCandidate] {
        switch source {
        case .itunes:
            return try await fetchITunes(query: query, maxResults: maxResults, session: session)
        case .musicBrainz:
            return try await fetchMusicBrainz(query: query, maxResults: maxResults, session: session)
        case .deezer:
            return try await fetchDeezer(query: query, maxResults: maxResults, session: session)
        case .discogs:
            guard let discogsToken else {
                if sourceSelection == .discogs {
                    throw LookupError.missingDiscogsToken
                }
                return []
            }
            return try await fetchDiscogs(query: query, maxResults: maxResults, session: session, token: discogsToken)
        case .wikipedia:
            return try await fetchWikipedia(query: query, maxResults: maxResults, session: session)
        case .youTube:
            guard let apiKey = youTubeAPIKey() else {
                // Missing key is only an error when YouTube was asked for on its
                // own; inside a wider selection it just contributes nothing.
                if sourceSelection == .youTube {
                    throw LookupError.missingYouTubeKey
                }
                return []
            }
            return try await fetchYouTube(query: query, maxResults: maxResults, session: session, apiKey: apiKey)
        }
    }

    private static func normalize(query: Query) -> Query {
        Query(
            title: searchableTerm(query.title),
            artist: searchableTerm(query.artist),
            album: searchableTerm(query.album)
        )
    }

    static func searchableTerm(_ rawValue: String) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        while removeTrailingDescriptor(from: &value) {
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        return value
    }

    /// DJ version/mix descriptors that should be preserved from the original
    /// title when applying an online match. Online stores return the plain song
    /// title (e.g. "Feel So Close"), but DJs rely on the variant marker
    /// ("(Intro)", "(Clean)", "(Extended)", …) staying on the title.
    static let djDescriptorKeywords: [String] = [
        "intro", "outro", "clean", "dirty", "extended", "acapella", "a cappella",
        "instrumental", "radio", "edit", "remix", "mix", "club", "vip", "bootleg",
        "rework", "refix", "flip", "mashup", "dub", "short edit", "long edit",
        "quick hit", "quickie", "transition", "redrum", "hype", "segue", "snippet",
        "aca in", "aca out", "in out", "starter"
    ]

    /// Returns `candidateTitle` with any DJ-descriptor parenthetical/bracket
    /// groups from `originalTitle` preserved. Store matches drop these markers,
    /// so when the user applies a match we re-attach the original's DJ terms
    /// (e.g. picking "Feel So Close" for "Feel So Close (Intro)" keeps
    /// "(Intro)"). Non-DJ parentheticals like "(feat. X)" are left off, and a
    /// descriptor already present on the candidate isn't duplicated.
    public static func titlePreservingDescriptors(from candidateTitle: String, original originalTitle: String) -> String {
        var result = candidateTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else { return candidateTitle }

        for group in bracketedGroups(in: originalTitle) where groupContainsDJKeyword(group) {
            let innerLower = bracketedInner(group).lowercased()
            if result.lowercased().contains(innerLower) { continue }
            result += " \(group)"
        }

        return result
    }

    /// Returns `title` with the artist stripped when it is written the messy
    /// "Artist - Song" (or "Song - Artist") way. Only an exact leading or
    /// trailing artist match against a real separator is removed, so a song
    /// genuinely called "Justice For All", or "Sail" by AWOLNATION tagged
    /// "Sail - Extended Mix", is left alone. The artist belongs in the artist
    /// tag, never the title.
    public static func titleWithoutArtist(_ title: String, artist: String) -> String {
        let artistName = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artistName.isEmpty, !trimmed.isEmpty else { return title }

        let separators = [" - ", " \u{2013} ", " \u{2014} ", " -- ", ": "]
        let lowerTitle = trimmed.lowercased()

        for separator in separators {
            let prefix = (artistName + separator).lowercased()
            if lowerTitle.hasPrefix(prefix) {
                let stripped = String(trimmed.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty ? title : stripped
            }
            let suffix = (separator + artistName).lowercased()
            if lowerTitle.hasSuffix(suffix) {
                let stripped = String(trimmed.dropLast(suffix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty ? title : stripped
            }
        }

        return title
    }

    /// Returns the `(…)` and `[…]` groups from a title, in order, with brackets.
    private static func bracketedGroups(in title: String) -> [String] {
        let pattern = #"[\(\[][^\(\)\[\]]*[\)\]]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(title.startIndex..., in: title)
        return regex.matches(in: title, options: [], range: range).compactMap { match in
            Range(match.range, in: title).map { String(title[$0]) }
        }
    }

    private static func bracketedInner(_ group: String) -> String {
        var inner = group
        if inner.hasPrefix("(") || inner.hasPrefix("[") { inner.removeFirst() }
        if inner.hasSuffix(")") || inner.hasSuffix("]") { inner.removeLast() }
        return inner.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func groupContainsDJKeyword(_ group: String) -> Bool {
        let inner = bracketedInner(group).lowercased()
        guard !inner.isEmpty else { return false }
        return djDescriptorKeywords.contains { keyword in
            inner.range(of: "\\b\(NSRegularExpression.escapedPattern(for: keyword))\\b", options: .regularExpression) != nil
        }
    }

    private static func removeTrailingDescriptor(from value: inout String) -> Bool {
        let patterns = [#"\s*\([^()]*\)\s*$"#, #"\s*\[[^\[\]]*\]\s*$"#]

        for pattern in patterns {
            if let range = value.range(of: pattern, options: .regularExpression) {
                value.removeSubrange(range)
                return true
            }
        }

        return false
    }

    private static func deduplicated(candidates: [OnlineTrackMetadataCandidate]) -> [OnlineTrackMetadataCandidate] {
        var seen = Set<String>()
        var unique: [OnlineTrackMetadataCandidate] = []

        for candidate in candidates {
            let fingerprint = [
                candidate.title.lowercased(),
                candidate.artist.lowercased(),
                candidate.album.lowercased(),
                String(candidate.year ?? 0)
            ].joined(separator: "|")

            if seen.insert(fingerprint).inserted {
                unique.append(candidate)
            }
        }

        return unique
    }

    private static func fetchITunes(
        query: Query,
        maxResults: Int,
        session: URLSession
    ) async throws -> [OnlineTrackMetadataCandidate] {
        let searchTerm = [query.artist, query.title, query.album]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !searchTerm.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: searchTerm),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: String(max(1, maxResults)))
        ]

        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("EZLibrary/1.0 (metadata lookup)", forHTTPHeaderField: "User-Agent")

        let data = try await performRequest(request, source: .itunes, pacer: .itunes, session: session)
        let decoded: ITunesSearchResponse
        do {
            decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)
        } catch {
            throw LookupError.sourceRequestFailed(.itunes, "Received an unexpected response format from iTunes.")
        }

        return decoded.results.map { item in
            OnlineTrackMetadataCandidate(
                source: .itunes,
                title: item.trackName ?? "",
                artist: item.artistName ?? "",
                album: item.collectionName ?? "",
                genre: item.primaryGenreName ?? "",
                year: yearFromDateString(item.releaseDate),
                bpm: nil,
                artworkURL: upscaledITunesArtworkURL(item.artworkUrl100),
                durationSeconds: item.trackTimeMillis.map { $0 / 1000 }
            )
        }
    }

    /// iTunes returns a 100x100 art URL; swap the size token for a larger one.
    private static func upscaledITunesArtworkURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        let upscaled = raw.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return URL(string: upscaled) ?? URL(string: raw)
    }

    /// Deezer's public catalog needs no credential and reports track length,
    /// which is what makes it worth a fourth request: duration is how a radio
    /// edit and an extended mix of the same song are told apart.
    ///
    /// Search results carry no genre or release year — those live on the album
    /// object behind a second request — so this fills what one call can answer
    /// and leaves the rest to the other sources.
    private static func fetchDeezer(
        query: Query,
        maxResults: Int,
        session: URLSession
    ) async throws -> [OnlineTrackMetadataCandidate] {
        let searchTerm = [query.artist, query.title]
            .filter { !$0.isEmpty }
            .joined(separator: " ")

        guard !searchTerm.isEmpty else { return [] }

        var components = URLComponents(string: "https://api.deezer.com/search")
        components?.queryItems = [
            URLQueryItem(name: "q", value: searchTerm),
            URLQueryItem(name: "limit", value: String(max(1, maxResults)))
        ]

        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("EZLibrary/1.0 (metadata lookup)", forHTTPHeaderField: "User-Agent")

        let data = try await performRequest(request, source: .deezer, pacer: .deezer, session: session)
        let decoded: DeezerSearchResponse
        do {
            decoded = try JSONDecoder().decode(DeezerSearchResponse.self, from: data)
        } catch {
            throw LookupError.sourceRequestFailed(.deezer, "Received an unexpected response format from Deezer.")
        }

        // Search results carry no release date or genre — those live on the
        // album object. One extra request per distinct album (about a quarter
        // of a second) buys a second fast source for year and genre, which is
        // what lets a run skip MusicBrainz without losing the release year.
        let albumIDs = decoded.data.compactMap(\.album?.id).reduce(into: [Int]()) { unique, id in
            if !unique.contains(id), unique.count < maxAlbumLookups {
                unique.append(id)
            }
        }
        // Fetched concurrently: they are independent requests, and Deezer allows
        // roughly fifty a second, so doing them in series only added latency.
        let albumDetails = await withTaskGroup(
            of: (Int, DeezerAlbumDetail?).self
        ) { group -> [Int: DeezerAlbumDetail] in
            for albumID in albumIDs {
                group.addTask {
                    (albumID, await fetchDeezerAlbumDetail(id: albumID, session: session))
                }
            }
            var details: [Int: DeezerAlbumDetail] = [:]
            for await (albumID, detail) in group {
                details[albumID] = detail
            }
            return details
        }

        return decoded.data.map { item in
            let detail = item.album?.id.flatMap { albumDetails[$0] }
            return OnlineTrackMetadataCandidate(
                source: .deezer,
                title: item.title ?? "",
                artist: item.artist?.name ?? "",
                album: item.album?.title ?? "",
                genre: detail?.primaryGenre ?? "",
                year: yearFromDateString(detail?.releaseDate),
                bpm: nil,
                artworkURL: (item.album?.coverXL ?? item.album?.coverBig).flatMap(URL.init(string:)),
                durationSeconds: item.duration.map(Double.init)
            )
        }
    }

    /// How many distinct Deezer albums to look up per search.
    ///
    /// One. Measured over 24 tracks, raising it to two cost 25% more wall time
    /// (0.30s/track against 0.24s) and filled exactly the same number of years
    /// and genres — the top result's album is the one that matters, and the
    /// second lookup only bought requests. Deezer is paced at ten a second, so
    /// every extra call per track is felt directly across a library-sized run.
    private static let maxAlbumLookups = 1

    /// Best-effort: a failed album lookup costs the extra year and genre for
    /// that candidate, nothing more, so it must never fail the search.
    private static func fetchDeezerAlbumDetail(
        id: Int,
        session: URLSession
    ) async -> DeezerAlbumDetail? {
        guard let url = URL(string: "https://api.deezer.com/album/\(id)") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("EZLibrary/1.0 (metadata lookup)", forHTTPHeaderField: "User-Agent")

        guard let data = try? await performRequest(
            request,
            source: .deezer,
            pacer: .deezer,
            session: session
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(DeezerAlbumDetail.self, from: data)
    }

    private static func fetchMusicBrainz(
        query: Query,
        maxResults: Int,
        session: URLSession
    ) async throws -> [OnlineTrackMetadataCandidate] {
        let terms = [
            query.title.isEmpty ? nil : "recording:\"\(query.title)\"",
            query.artist.isEmpty ? nil : "artist:\"\(query.artist)\"",
            query.album.isEmpty ? nil : "release:\"\(query.album)\""
        ]
        .compactMap { $0 }

        guard !terms.isEmpty else { return [] }

        var components = URLComponents(string: "https://musicbrainz.org/ws/2/recording/")
        components?.queryItems = [
            URLQueryItem(name: "query", value: terms.joined(separator: " AND ")),
            URLQueryItem(name: "fmt", value: "json"),
            URLQueryItem(name: "limit", value: String(max(1, maxResults)))
        ]

        guard let url = components?.url else { return [] }
        var request = URLRequest(url: url)
        request.setValue("EZLibrary/1.0 (metadata lookup)", forHTTPHeaderField: "User-Agent")

        let data = try await performRequest(request, source: .musicBrainz, pacer: .musicBrainz, session: session)
        let decoded: MusicBrainzResponse
        do {
            decoded = try JSONDecoder().decode(MusicBrainzResponse.self, from: data)
        } catch {
            throw LookupError.sourceRequestFailed(.musicBrainz, "Received an unexpected response format from MusicBrainz.")
        }

        return decoded.recordings.map { recording in
            let artist = recording.artistCredit?.first?.name ?? ""
            let firstRelease = recording.releases?.first
            let album = firstRelease?.title ?? ""
            let genre = recording.tags?.first?.name ?? ""

            return OnlineTrackMetadataCandidate(
                source: .musicBrainz,
                title: recording.title,
                artist: artist,
                album: album,
                genre: genre,
                year: yearFromDateString(recording.firstReleaseDate),
                bpm: nil,
                artworkURL: coverArtArchiveURL(releaseID: firstReleaseIDWithArt(recording.releases))
            )
        }
    }

    /// Prefers a release the Cover Art Archive flags as having front art, then
    /// falls back to the first release with an MBID.
    private static func firstReleaseIDWithArt(_ releases: [MusicBrainzRelease]?) -> String? {
        guard let releases else { return nil }
        if let withArt = releases.first(where: { ($0.coverArtArchive?.front ?? false) && $0.id != nil }) {
            return withArt.id
        }
        return releases.first(where: { $0.id != nil })?.id
    }

    /// Builds a Cover Art Archive front-image URL for a release MBID. The
    /// endpoint 404s when no art exists, which the caller handles gracefully.
    private static func coverArtArchiveURL(releaseID: String?) -> URL? {
        guard let releaseID, !releaseID.isEmpty else { return nil }
        return URL(string: "https://coverartarchive.org/release/\(releaseID)/front-500")
    }

    private static func fetchDiscogs(
        query: Query,
        maxResults: Int,
        session: URLSession,
        token: String
    ) async throws -> [OnlineTrackMetadataCandidate] {
        var components = URLComponents(string: "https://api.discogs.com/database/search")

        var queryItems: [URLQueryItem] = [
            URLQueryItem(name: "type", value: "release"),
            URLQueryItem(name: "per_page", value: String(max(1, maxResults))),
            URLQueryItem(name: "page", value: "1")
        ]

        if !query.artist.isEmpty {
            queryItems.append(URLQueryItem(name: "artist", value: query.artist))
        }
        if !query.title.isEmpty {
            queryItems.append(URLQueryItem(name: "track", value: query.title))
        }
        if !query.album.isEmpty {
            queryItems.append(URLQueryItem(name: "release_title", value: query.album))
        }

        if query.artist.isEmpty && query.title.isEmpty && query.album.isEmpty {
            queryItems.append(URLQueryItem(name: "q", value: "music"))
        }

        components?.queryItems = queryItems
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("EZLibrary/1.0 (metadata lookup)", forHTTPHeaderField: "User-Agent")
        request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")

        let data = try await performRequest(
            request,
            source: .discogs,
            pacer: .discogs,
            session: session,
            errorMessage: { body in
                (try? JSONDecoder().decode(DiscogsErrorResponse.self, from: body))?.message
            }
        )

        let decoded: DiscogsSearchResponse
        do {
            decoded = try JSONDecoder().decode(DiscogsSearchResponse.self, from: data)
        } catch {
            throw LookupError.sourceRequestFailed(
                .discogs,
                "Received an unexpected response format from Discogs."
            )
        }

        return decoded.results.map { result in
            let split = splitDiscogsTitle(result.title)
            let title = query.title.isEmpty ? (split.album ?? "") : query.title
            let artist = split.artist ?? query.artist
            let album = query.album.isEmpty ? (split.album ?? "") : query.album

            return OnlineTrackMetadataCandidate(
                source: .discogs,
                title: title,
                artist: artist,
                album: album,
                genre: result.genre?.first ?? "",
                year: result.year,
                bpm: nil,
                comment: result.id.map { "Discogs release #\($0)" } ?? "",
                artworkURL: discogsArtworkURL(result)
            )
        }
    }

    /// Discogs search results include a full cover image (and a thumbnail
    /// fallback); placeholder spacer images are ignored.
    private static func discogsArtworkURL(_ result: DiscogsSearchResult) -> URL? {
        for candidate in [result.coverImage, result.thumb] {
            guard let raw = candidate?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else { continue }
            if raw.contains("spacer.gif") { continue }
            if let url = URL(string: raw) { return url }
        }
        return nil
    }

    private static func discogsToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> String? {
        if let token = (environment[discogsTokenEnvironmentKey] ?? environment[legacyDiscogsTokenEnvironmentKey])?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        if let token = userDefaults.string(forKey: discogsTokenDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
            return token
        }
        return nil
    }

    private static func splitDiscogsTitle(_ rawTitle: String?) -> (artist: String?, album: String?) {
        guard let rawTitle, !rawTitle.isEmpty else { return (nil, nil) }
        let parts = rawTitle.components(separatedBy: " - ")
        if parts.count >= 2 {
            return (
                artist: parts.first?.trimmingCharacters(in: .whitespacesAndNewlines),
                album: parts.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return (nil, rawTitle.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private static func yearFromDateString(_ value: String?) -> Int? {
        guard let value, value.count >= 4 else { return nil }
        return Int(value.prefix(4))
    }

    // MARK: - Wikipedia

    /// How many Wikipedia pages to pull a summary for per search.
    ///
    /// Each summary is a second request, and only the top song page carries the
    /// original album we want, so this is kept small deliberately: two is
    /// enough to survive the top hit being a disambiguation or artist page
    /// without turning a whole-library run into three requests a track.
    private static let maxWikipediaSummaries = 2

    /// Wikipedia is free, keyless, and unusually good at naming the *original*
    /// album a song first appeared on, which the catalog APIs get wrong by
    /// returning the single or a compilation. It carries no duration and its
    /// genre is only sometimes stated, so it contributes an album and a year
    /// and leaves identity to the sources that report length.
    private static func fetchWikipedia(
        query: Query,
        maxResults: Int,
        session: URLSession
    ) async throws -> [OnlineTrackMetadataCandidate] {
        let searchTerm = [query.artist, query.title]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !searchTerm.isEmpty else { return [] }

        var components = URLComponents(string: "https://en.wikipedia.org/w/rest.php/v1/search/page")
        components?.queryItems = [
            URLQueryItem(name: "q", value: searchTerm),
            URLQueryItem(name: "limit", value: String(min(max(1, maxResults), 5)))
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(wikipediaUserAgent, forHTTPHeaderField: "User-Agent")

        let data = try await performRequest(request, source: .wikipedia, pacer: .wikipedia, session: session)
        let decoded: WikipediaSearchResponse
        do {
            decoded = try JSONDecoder().decode(WikipediaSearchResponse.self, from: data)
        } catch {
            throw LookupError.sourceRequestFailed(.wikipedia, "Received an unexpected response format from Wikipedia.")
        }

        // Prefer pages that read like a song or single; only if none do is it
        // worth spending a summary request on the rest.
        let songPages = decoded.pages.filter(isLikelySongPage)
        let pages = Array((songPages.isEmpty ? decoded.pages : songPages).prefix(maxWikipediaSummaries))
        guard !pages.isEmpty else { return [] }

        let summaries = await withTaskGroup(
            of: (Int, WikipediaSummary?).self
        ) { group -> [Int: WikipediaSummary] in
            for (index, page) in pages.enumerated() {
                let title = page.key ?? page.title
                group.addTask {
                    (index, await fetchWikipediaSummary(title: title, session: session))
                }
            }
            var byIndex: [Int: WikipediaSummary] = [:]
            for await (index, summary) in group {
                byIndex[index] = summary
            }
            return byIndex
        }

        var candidates: [OnlineTrackMetadataCandidate] = []
        for (index, page) in pages.enumerated() {
            guard let summary = summaries[index] else { continue }
            let parsed = parseWikipediaSummary(
                description: summary.description ?? page.description,
                extract: summary.extract ?? ""
            )
            // A page that names no album, year, or genre is not evidence about
            // any of them, and its own title is the song — never something to
            // write over the tag with.
            guard !parsed.album.isEmpty || parsed.year != nil || !parsed.genre.isEmpty else { continue }
            candidates.append(OnlineTrackMetadataCandidate(
                source: .wikipedia,
                title: query.title,
                artist: query.artist,
                album: parsed.album,
                genre: parsed.genre,
                year: parsed.year,
                bpm: nil,
                comment: "Wikipedia: \(page.title)"
            ))
        }
        return candidates
    }

    /// Best-effort: a page whose summary won't load costs its album and year,
    /// nothing more, so it must never fail the whole search.
    private static func fetchWikipediaSummary(
        title: String,
        session: URLSession
    ) async -> WikipediaSummary? {
        let allowed = CharacterSet.urlPathAllowed
        let encoded = title.addingPercentEncoding(withAllowedCharacters: allowed) ?? title
        guard let url = URL(string: "https://en.wikipedia.org/api/rest_v1/page/summary/\(encoded)") else {
            return nil
        }
        var request = URLRequest(url: url)
        request.setValue(wikipediaUserAgent, forHTTPHeaderField: "User-Agent")

        guard let data = try? await performRequest(
            request,
            source: .wikipedia,
            pacer: .wikipedia,
            session: session
        ) else {
            return nil
        }
        return try? JSONDecoder().decode(WikipediaSummary.self, from: data)
    }

    /// True when a search result's one-line description marks it as a song or
    /// single rather than an artist, album, or disambiguation page.
    static func isLikelySongPage(_ page: WikipediaSearchPage) -> Bool {
        guard let description = page.description?.lowercased() else { return false }
        return description.contains("song") || description.contains("single")
    }

    /// Reads the album, year, and (when stated) genre out of a Wikipedia
    /// summary. Pure so it can be tested against real summary text without the
    /// network.
    static func parseWikipediaSummary(
        description: String?,
        extract: String
    ) -> (album: String, year: Int?, genre: String) {
        let album = wikipediaAlbum(fromExtract: extract)
        let year = album.year ?? wikipediaReleaseYear(description: description, extract: extract)
        let genre = inferGenre(fromText: [description ?? "", extract].joined(separator: " "))
        return (album: album.name, year: year, genre: genre)
    }

    /// Pulls the album a summary says a song appeared on, plus the year in
    /// parentheses beside it when present.
    ///
    /// Bounded on purpose. Wikipedia leads phrase this as "…from their fourth
    /// studio album Hyperdrama (2024)." or "…, released in 2024." The capture
    /// stops at the parenthesised year, at punctuation, or at a word that
    /// clearly continues the sentence ("released", "which", "was"), and a
    /// result longer than a plausible album title is discarded as an
    /// over-capture rather than written into a tag.
    static func wikipediaAlbum(fromExtract extract: String) -> (name: String, year: Int?) {
        let pattern = #"\balbums?\s+(?:titled\s+|called\s+|named\s+)?([A-Z][^.,;:\n(]*?)(?=\s*\((?:19|20)\d{2}\)|\s*[.,;:)\n]|\s+(?:released|which|featuring|feat\.?|was|is|has|had|peaked|reached|became|debuted|spent)\b|$)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return ("", nil) }
        let range = NSRange(extract.startIndex..., in: extract)
        guard let match = regex.firstMatch(in: extract, options: [], range: range),
              let nameRange = Range(match.range(at: 1), in: extract) else {
            return ("", nil)
        }

        let name = String(extract[nameRange]).trimmingCharacters(in: .whitespacesAndNewlines)
        // Real album titles are short; anything longer is a captured sentence.
        guard !name.isEmpty, name.split(separator: " ").count <= 8 else { return ("", nil) }

        // A "(YYYY)" immediately after the album is that album's year.
        var year: Int?
        let tail = extract[nameRange.upperBound...]
        if let yearMatch = tail.range(of: #"^\s*\(((?:19|20)\d{2})\)"#, options: .regularExpression) {
            year = Int(tail[yearMatch].filter(\.isNumber))
        }
        return (name, year)
    }

    /// The release year, preferring a year the one-line description leads with
    /// ("2024 single by …"), then a year stated next to "released", then the
    /// first plausible year anywhere in the summary.
    static func wikipediaReleaseYear(description: String?, extract: String) -> Int? {
        if let description,
           let match = description.range(of: #"^\s*((?:19|20)\d{2})\b"#, options: .regularExpression) {
            return Int(description[match].filter(\.isNumber))
        }
        if let match = extract.range(of: #"released\b[^.]*?\b((?:19|20)\d{2})\b"#, options: [.regularExpression, .caseInsensitive]),
           let year = extract[match].range(of: #"(?:19|20)\d{2}"#, options: .regularExpression) {
            return Int(extract[match][year])
        }
        if let match = extract.range(of: #"\b(?:19|20)\d{2}\b"#, options: .regularExpression) {
            return Int(extract[match])
        }
        return nil
    }

    // MARK: - YouTube

    /// A genre-of-last-resort source. It needs a runtime API key and spends
    /// quota, so it is never in the free or fast sets and returns a candidate
    /// only when a genre can actually be read from the video's text — there is
    /// no point spending a quota unit to contribute nothing.
    private static func fetchYouTube(
        query: Query,
        maxResults: Int,
        session: URLSession,
        apiKey: String
    ) async throws -> [OnlineTrackMetadataCandidate] {
        let searchTerm = [query.artist, query.title]
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !searchTerm.isEmpty else { return [] }

        var components = URLComponents(string: "https://www.googleapis.com/youtube/v3/search")
        components?.queryItems = [
            URLQueryItem(name: "part", value: "snippet"),
            URLQueryItem(name: "type", value: "video"),
            URLQueryItem(name: "videoCategoryId", value: "10"),
            URLQueryItem(name: "maxResults", value: String(min(max(1, maxResults), 3))),
            URLQueryItem(name: "q", value: searchTerm),
            URLQueryItem(name: "key", value: apiKey)
        ]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue("EZLibrary/1.0 (metadata lookup)", forHTTPHeaderField: "User-Agent")

        let data = try await performRequest(
            request,
            source: .youTube,
            pacer: .youTube,
            session: session,
            errorMessage: { body in
                (try? JSONDecoder().decode(YouTubeErrorResponse.self, from: body))?.error?.message
            }
        )

        let decoded: YouTubeSearchResponse
        do {
            decoded = try JSONDecoder().decode(YouTubeSearchResponse.self, from: data)
        } catch {
            throw LookupError.sourceRequestFailed(.youTube, "Received an unexpected response format from YouTube.")
        }

        return decoded.items.compactMap { item -> OnlineTrackMetadataCandidate? in
            guard let snippet = item.snippet else { return nil }
            let text = [snippet.title, snippet.channelTitle, snippet.description]
                .compactMap { $0 }
                .joined(separator: " ")
            let genre = inferGenre(fromText: text)
            guard !genre.isEmpty else { return nil }
            return OnlineTrackMetadataCandidate(
                source: .youTube,
                title: query.title,
                artist: query.artist,
                album: "",
                genre: genre,
                year: nil,
                bpm: nil,
                comment: "YouTube: \(snippet.title ?? "")"
            )
        }
    }

    static func youTubeAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> String? {
        if let key = (environment[youTubeAPIKeyEnvironmentKey] ?? environment[legacyYouTubeAPIKeyEnvironmentKey])?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        if let key = userDefaults.string(forKey: youTubeAPIKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !key.isEmpty {
            return key
        }
        return nil
    }

    // MARK: - Genre inference from free text

    /// Display genre paired with the lowercased needle to find it by. Ordered
    /// most specific first so "deep house" wins over "house" and "hip hop" is
    /// not shadowed by "pop".
    private static let genreKeywords: [(needle: String, genre: String)] = [
        ("drum and bass", "Drum & Bass"), ("drum & bass", "Drum & Bass"), ("drum n bass", "Drum & Bass"),
        ("hip hop", "Hip Hop"), ("hip-hop", "Hip Hop"),
        ("rhythm and blues", "R&B"), ("r&b", "R&B"),
        ("deep house", "Deep House"), ("tech house", "Tech House"), ("progressive house", "Progressive House"),
        ("future house", "Future House"), ("electro house", "Electro House"),
        ("nu disco", "Nu Disco"), ("big room", "Big Room"),
        ("synth-pop", "Synth-pop"), ("synthpop", "Synth-pop"), ("new wave", "New Wave"),
        ("dream pop", "Dream Pop"), ("indie pop", "Indie Pop"), ("indie rock", "Indie Rock"),
        ("hard rock", "Hard Rock"), ("classic rock", "Classic Rock"), ("punk rock", "Punk Rock"),
        ("pop punk", "Pop Punk"), ("heavy metal", "Heavy Metal"), ("death metal", "Death Metal"),
        ("black metal", "Black Metal"), ("dancehall", "Dancehall"), ("reggaeton", "Reggaeton"),
        ("afrobeats", "Afrobeats"), ("afrobeat", "Afrobeat"), ("trip hop", "Trip Hop"),
        ("lo-fi", "Lo-fi"),
        ("house", "House"), ("techno", "Techno"), ("trance", "Trance"), ("dubstep", "Dubstep"),
        ("electro", "Electro"), ("electronica", "Electronica"), ("electronic", "Electronic"),
        ("disco", "Disco"), ("funk", "Funk"), ("soul", "Soul"), ("gospel", "Gospel"),
        ("jazz", "Jazz"), ("blues", "Blues"), ("reggae", "Reggae"), ("grime", "Grime"),
        ("country", "Country"), ("folk", "Folk"), ("classical", "Classical"), ("ambient", "Ambient"),
        ("bluegrass", "Bluegrass"), ("salsa", "Salsa"), ("bachata", "Bachata"), ("cumbia", "Cumbia"),
        ("metal", "Metal"), ("punk", "Punk"), ("indie", "Indie"), ("rap", "Hip Hop"),
        ("rock", "Rock"), ("pop", "Pop"), ("latin", "Latin")
    ]

    /// The first genre named in a block of free text, or an empty string.
    ///
    /// Shared by Wikipedia and YouTube, whose payloads carry genre only in
    /// prose. Word-boundary matched so "rock" is not found inside "rocky" and
    /// "pop" not inside "populist".
    static func inferGenre(fromText text: String) -> String {
        let lowered = text.lowercased()
        guard !lowered.isEmpty else { return "" }

        var earliest: (index: String.Index, genre: String)?
        for (needle, genre) in genreKeywords {
            let escaped = NSRegularExpression.escapedPattern(for: needle)
            // Word-boundary matched so "rock" is not found in "rocky" nor "pop"
            // in "populist". A trailing \b still matches a genre butted against
            // punctuation ("house." / "hip hop,").
            guard let range = lowered.range(of: "\\b\(escaped)\\b", options: .regularExpression) else { continue }
            if earliest == nil || range.lowerBound < earliest!.index {
                earliest = (range.lowerBound, genre)
            }
        }
        guard let earliest else { return "" }
        return GenreCanonicalizer.canonical(earliest.genre)
    }

    /// A 4-digit release year read out of free text like a file name or an
    /// album title, for the common case where the ID3 year frame is empty but
    /// the file is named "… (2019).mp3" or the album is "Greatest Hits 1999".
    /// Prefers a bracketed year, then the earliest plausible standalone
    /// 19xx/20xx. Nil when nothing in range is found.
    static func inferReleaseYear(fromText text: String) -> Int? {
        func inRange(_ year: Int) -> Bool { (1900...2100).contains(year) }

        // A parenthesised or bracketed year is almost always the release year.
        if let range = text.range(of: #"[\(\[]((?:19|20)\d{2})[\)\]]"#, options: .regularExpression) {
            let digits = text[range].filter(\.isNumber)
            if let year = Int(digits.prefix(4)), inRange(year) { return year }
        }

        // Otherwise the earliest plausible standalone year; earliest so a name
        // like "1999 (2021 Remaster)" reads as the original release.
        guard let scanner = try? NSRegularExpression(pattern: #"\b(?:19|20)\d{2}\b"#) else { return nil }
        let ns = text as NSString
        var years: [Int] = []
        scanner.enumerateMatches(in: text, range: NSRange(location: 0, length: ns.length)) { match, _, _ in
            if let match, let year = Int(ns.substring(with: match.range)), inRange(year) {
                years.append(year)
            }
        }
        return years.min()
    }
}

private struct ITunesSearchResponse: Decodable {
    let results: [ITunesTrack]
}

private struct ITunesTrack: Decodable {
    let trackName: String?
    let artistName: String?
    let collectionName: String?
    let primaryGenreName: String?
    let releaseDate: String?
    let artworkUrl100: String?
    let trackTimeMillis: Double?
}

private struct DeezerSearchResponse: Decodable {
    let data: [DeezerTrack]
}

private struct DeezerTrack: Decodable {
    let title: String?
    let duration: Int?
    let artist: DeezerArtist?
    let album: DeezerAlbum?
}

private struct DeezerArtist: Decodable {
    let name: String?
}

private struct DeezerAlbumDetail: Decodable {
    let releaseDate: String?
    let genres: DeezerGenreList?

    var primaryGenre: String {
        genres?.data?.first?.name ?? ""
    }

    enum CodingKeys: String, CodingKey {
        case releaseDate = "release_date"
        case genres
    }
}

private struct DeezerGenreList: Decodable {
    let data: [DeezerGenre]?
}

private struct DeezerGenre: Decodable {
    let name: String?
}

private struct DeezerAlbum: Decodable {
    let id: Int?
    let title: String?
    let coverBig: String?
    let coverXL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case coverBig = "cover_big"
        case coverXL = "cover_xl"
    }
}

private struct MusicBrainzResponse: Decodable {
    let recordings: [MusicBrainzRecording]
}

private struct MusicBrainzRecording: Decodable {
    let title: String
    let firstReleaseDate: String?
    let artistCredit: [MusicBrainzArtistCredit]?
    let releases: [MusicBrainzRelease]?
    let tags: [MusicBrainzTag]?

    enum CodingKeys: String, CodingKey {
        case title
        case firstReleaseDate = "first-release-date"
        case artistCredit = "artist-credit"
        case releases
        case tags
    }
}

private struct MusicBrainzArtistCredit: Decodable {
    let name: String?
}

private struct MusicBrainzRelease: Decodable {
    let id: String?
    let title: String?
    let coverArtArchive: MusicBrainzCoverArtArchive?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case coverArtArchive = "cover-art-archive"
    }
}

private struct MusicBrainzCoverArtArchive: Decodable {
    let front: Bool?
}

private struct MusicBrainzTag: Decodable {
    let name: String?
}

private struct DiscogsSearchResponse: Decodable {
    let results: [DiscogsSearchResult]
}

private struct DiscogsSearchResult: Decodable {
    let id: Int?
    let title: String?
    let year: Int?
    let genre: [String]?
    let coverImage: String?
    let thumb: String?

    enum CodingKeys: String, CodingKey {
        case id
        case title
        case year
        case genre
        case coverImage = "cover_image"
        case thumb
    }
}

private struct DiscogsErrorResponse: Decodable {
    let message: String?
}

// Internal rather than private so the page-classification helper and its tests
// can name the type.
struct WikipediaSearchResponse: Decodable {
    let pages: [WikipediaSearchPage]
}

struct WikipediaSearchPage: Decodable {
    let key: String?
    let title: String
    let description: String?
    let excerpt: String?
}

struct WikipediaSummary: Decodable {
    let title: String?
    let description: String?
    let extract: String?
}

private struct YouTubeSearchResponse: Decodable {
    let items: [YouTubeSearchItem]
}

private struct YouTubeSearchItem: Decodable {
    let snippet: YouTubeSnippet?
}

private struct YouTubeSnippet: Decodable {
    let title: String?
    let channelTitle: String?
    let description: String?
}

private struct YouTubeErrorResponse: Decodable {
    let error: YouTubeErrorDetail?
}

private struct YouTubeErrorDetail: Decodable {
    let message: String?
}