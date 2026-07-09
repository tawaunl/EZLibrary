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

    public init(
        id: UUID = UUID(),
        source: OnlineMetadataSource,
        title: String,
        artist: String,
        album: String,
        genre: String,
        year: Int?,
        bpm: Double?,
        comment: String = ""
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
    }
}

public enum OnlineTrackMetadataLookupService {
    public static let discogsTokenEnvironmentKey = "SERATOTOOLS_DISCOGS_TOKEN"
    public static let discogsTokenDefaultsKey = "SeratoToolsDiscogsToken"

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
                return "Discogs lookup requires an API token. Set SERATOTOOLS_DISCOGS_TOKEN or save SeratoToolsDiscogsToken in UserDefaults."
            case let .sourceRequestFailed(source, message):
                return "\(source.displayName) lookup failed: \(message)"
            }
        }
    }

    public static func lookup(
        query: Query,
        sourceSelection: SourceSelection = .all,
        maxResultsPerSource: Int = 8,
        session: URLSession = .shared
    ) async throws -> [OnlineTrackMetadataCandidate] {
        let normalized = normalize(query: query)
        guard !normalized.title.isEmpty || !normalized.artist.isEmpty || !normalized.album.isEmpty else {
            throw LookupError.missingSearchTerms
        }

        var combined: [OnlineTrackMetadataCandidate] = []
        for source in sourceSelection.enabledSources {
            do {
                switch source {
                case .itunes:
                    let results = try await fetchITunes(
                        query: normalized,
                        maxResults: maxResultsPerSource,
                        session: session
                    )
                    combined.append(contentsOf: results)
                case .musicBrainz:
                    let results = try await fetchMusicBrainz(
                        query: normalized,
                        maxResults: maxResultsPerSource,
                        session: session
                    )
                    combined.append(contentsOf: results)
                case .discogs:
                    guard let token = discogsToken() else {
                        if sourceSelection == .discogs {
                            throw LookupError.missingDiscogsToken
                        }
                        continue
                    }
                    let results = try await fetchDiscogs(
                        query: normalized,
                        maxResults: maxResultsPerSource,
                        session: session,
                        token: token
                    )
                    combined.append(contentsOf: results)
                }
            } catch {
                // In All Sources mode, one failing provider should not block
                // successful results from other providers.
                if sourceSelection == .all {
                    continue
                }
                throw error
            }
        }

        return deduplicated(candidates: combined)
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
                bpm: nil
            )
        }
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
            let album = recording.releases?.first?.title ?? ""
            let genre = recording.tags?.first?.name ?? ""

            return OnlineTrackMetadataCandidate(
                source: .musicBrainz,
                title: recording.title,
                artist: artist,
                album: album,
                genre: genre,
                year: yearFromDateString(recording.firstReleaseDate),
                bpm: nil
            )
        }
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
                comment: result.id.map { "Discogs release #\($0)" } ?? ""
            )
        }
    }

    private static func discogsToken(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> String? {
        if let token = environment[discogsTokenEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines), !token.isEmpty {
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
    let title: String?
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
}

private struct DiscogsErrorResponse: Decodable {
    let message: String?
}