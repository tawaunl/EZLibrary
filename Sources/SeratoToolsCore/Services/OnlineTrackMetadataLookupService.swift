import Foundation

public enum OnlineMetadataSource: String, CaseIterable, Sendable {
    case itunes
    case musicBrainz

    public var displayName: String {
        switch self {
        case .itunes:
            return "iTunes"
        case .musicBrainz:
            return "MusicBrainz"
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
    public enum SourceSelection: String, CaseIterable, Sendable {
        case all
        case itunes
        case musicBrainz

        public var displayName: String {
            switch self {
            case .all:
                return "All Sources"
            case .itunes:
                return "iTunes"
            case .musicBrainz:
                return "MusicBrainz"
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

        public var errorDescription: String? {
            switch self {
            case .missingSearchTerms:
                return "Enter at least a title, artist, or album before searching online."
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
            }
        }

        return deduplicated(candidates: combined)
    }

    private static func normalize(query: Query) -> Query {
        Query(
            title: query.title.trimmingCharacters(in: .whitespacesAndNewlines),
            artist: query.artist.trimmingCharacters(in: .whitespacesAndNewlines),
            album: query.album.trimmingCharacters(in: .whitespacesAndNewlines)
        )
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