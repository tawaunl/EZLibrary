import Foundation

public enum OnlineMetadataSource: String, CaseIterable, Sendable {
    case itunes
    case musicBrainz
    case discogs

    public var displayName: String {
        switch self {
        case .itunes:
            return "iTunes"
        case .musicBrainz:
            return "MusicBrainz"
        case .discogs:
            return "Discogs"
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
        artworkURL: URL? = nil
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

public enum OnlineTrackMetadataLookupService {
    public static let discogsTokenEnvironmentKey = "EZLIBRARY_DISCOGS_TOKEN"
    /// Legacy environment key, still honored for backward compatibility.
    public static let legacyDiscogsTokenEnvironmentKey = "SERATOTOOLS_DISCOGS_TOKEN"
    public static let discogsTokenDefaultsKey = "SeratoToolsDiscogsToken"

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
        case discogs

        public var displayName: String {
            switch self {
            case .all:
                return "All Sources"
            case .itunes:
                return "iTunes"
            case .musicBrainz:
                return "MusicBrainz"
            case .discogs:
                return "Discogs"
            }
        }

        fileprivate var enabledSources: [OnlineMetadataSource] {
            switch self {
            case .all:
                return OnlineMetadataSource.allCases
            case .itunes:
                return [.itunes]
            case .musicBrainz:
                return [.musicBrainz]
            case .discogs:
                return [.discogs]
            }
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
        case sourceRequestFailed(OnlineMetadataSource, String)

        public var errorDescription: String? {
            switch self {
            case .missingSearchTerms:
                return "Enter at least a title, artist, or album before searching online."
            case .missingDiscogsToken:
                return "Discogs lookup requires an API token. Set EZLIBRARY_DISCOGS_TOKEN or save a Discogs token in the app settings."
            case let .sourceRequestFailed(source, message):
                return "\(source.displayName) lookup failed: \(message)"
            }
        }
    }

    public static func lookup(
        query: Query,
        sourceSelection: SourceSelection = .all,
        maxResultsPerSource: Int = 8,
        session: URLSession = defaultSession
    ) async throws -> [OnlineTrackMetadataCandidate] {
        let normalized = normalize(query: query)
        guard !normalized.title.isEmpty || !normalized.artist.isEmpty || !normalized.album.isEmpty else {
            throw LookupError.missingSearchTerms
        }

        let cacheKey = cacheKey(for: normalized, sourceSelection: sourceSelection)
        if let cached = await OnlineMetadataLookupCache.shared.get(cacheKey) {
            return cached
        }

        let result: [OnlineTrackMetadataCandidate]
        if sourceSelection == .all {
            let token = discogsToken()
            let combined = await withTaskGroup(of: [OnlineTrackMetadataCandidate].self) { group in
                for source in sourceSelection.enabledSources {
                    group.addTask {
                        do {
                            return try await fetchCandidates(
                                from: source,
                                query: normalized,
                                maxResults: maxResultsPerSource,
                                session: session,
                                discogsToken: token,
                                sourceSelection: sourceSelection
                            )
                        } catch {
                            return []
                        }
                    }
                }

                var all: [OnlineTrackMetadataCandidate] = []
                for await sourceResults in group {
                    all.append(contentsOf: sourceResults)
                }
                return all
            }

            result = deduplicated(candidates: combined)
        } else {
            let results = try await fetchCandidates(
                from: sourceSelection.enabledSources[0],
                query: normalized,
                maxResults: maxResultsPerSource,
                session: session,
                discogsToken: discogsToken(),
                sourceSelection: sourceSelection
            )

            result = deduplicated(candidates: results)
        }

        await OnlineMetadataLookupCache.shared.set(cacheKey, results: result)
        return result
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

                guard sourceSelection == .all else {
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
                        await OnlineMetadataLookupCache.shared.set(cacheKey, results: deduped)
                        continuation.yield(deduped)
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                    return
                }

                let token = discogsToken()
                var accumulated: [OnlineTrackMetadataCandidate] = []
                await withTaskGroup(of: [OnlineTrackMetadataCandidate].self) { group in
                    for source in sourceSelection.enabledSources {
                        group.addTask {
                            (try? await fetchCandidates(
                                from: source,
                                query: normalized,
                                maxResults: maxResultsPerSource,
                                session: session,
                                discogsToken: token,
                                sourceSelection: sourceSelection
                            )) ?? []
                        }
                    }

                    for await sourceResults in group {
                        guard !sourceResults.isEmpty else { continue }
                        accumulated.append(contentsOf: sourceResults)
                        continuation.yield(deduplicated(candidates: accumulated))
                    }
                }

                await OnlineMetadataLookupCache.shared.set(cacheKey, results: deduplicated(candidates: accumulated))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    private static func cacheKey(for query: Query, sourceSelection: SourceSelection) -> String {
        [
            sourceSelection.rawValue,
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
        case .discogs:
            guard let discogsToken else {
                if sourceSelection == .discogs {
                    throw LookupError.missingDiscogsToken
                }
                return []
            }
            return try await fetchDiscogs(query: query, maxResults: maxResults, session: session, token: discogsToken)
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

        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(ITunesSearchResponse.self, from: data)

        return decoded.results.map { item in
            OnlineTrackMetadataCandidate(
                source: .itunes,
                title: item.trackName ?? "",
                artist: item.artistName ?? "",
                album: item.collectionName ?? "",
                genre: item.primaryGenreName ?? "",
                year: yearFromDateString(item.releaseDate),
                bpm: nil,
                artworkURL: upscaledITunesArtworkURL(item.artworkUrl100)
            )
        }
    }

    /// iTunes returns a 100x100 art URL; swap the size token for a larger one.
    private static func upscaledITunesArtworkURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        let upscaled = raw.replacingOccurrences(of: "100x100bb", with: "600x600bb")
        return URL(string: upscaled) ?? URL(string: raw)
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
        request.setValue("SeratoTools/1.0 (metadata lookup)", forHTTPHeaderField: "User-Agent")

        let (data, _) = try await session.data(for: request)
        let decoded = try JSONDecoder().decode(MusicBrainzResponse.self, from: data)

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
        request.setValue("SeratoTools/1.0 (metadata lookup)", forHTTPHeaderField: "User-Agent")
        request.setValue("Discogs token=\(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let apiError = (try? JSONDecoder().decode(DiscogsErrorResponse.self, from: data))?.message
            let message = apiError ?? "HTTP \(http.statusCode)"
            throw LookupError.sourceRequestFailed(.discogs, message)
        }

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