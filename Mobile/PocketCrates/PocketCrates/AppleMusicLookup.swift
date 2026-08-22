import Foundation

enum AppleMusicLookup {
    struct Result: Identifiable, Sendable {
        let id: Int
        let title: String
        let artistName: String
        let albumTitle: String?
        let genre: String?
        let year: Int?
        let artworkURL: URL?
    }

    // MARK: - Tag verification

    enum FieldStatus: Sendable {
        case confirmed
        case mismatch(suggested: String)
        case unverifiable
    }

    struct VerificationResult: Sendable {
        let bestMatch: Result?
        let title: FieldStatus
        let artist: FieldStatus
        let album: FieldStatus
        let genre: FieldStatus
        let year: FieldStatus

        var hasAnyMismatch: Bool {
            [title, artist, album, genre, year].contains { if case .mismatch = $0 { return true }; return false }
        }

        var confirmedCount: Int {
            [title, artist, album, genre, year].filter { if case .confirmed = $0 { return true }; return false }.count
        }
    }

    static func verify(
        title: String,
        artist: String,
        album: String,
        genre: String,
        year: String
    ) async throws -> VerificationResult {
        // Prefer Apple Intelligence: it searches iTunes itself with a smarter query
        if let analysis = await IntelligenceLookup.verify(
            title: title, artist: artist, album: album, genre: genre, year: year
        ) {
            guard analysis.matchFound else {
                return VerificationResult(
                    bestMatch: nil,
                    title: .unverifiable, artist: .unverifiable,
                    album: .unverifiable, genre: .unverifiable, year: .unverifiable
                )
            }
            // Build a synthetic Result for display (artwork not available in this path)
            let syntheticMatch = Result(
                id: -1,
                title: analysis.catalogTitle,
                artistName: analysis.catalogArtist,
                albumTitle: analysis.catalogAlbum.isEmpty ? nil : analysis.catalogAlbum,
                genre: analysis.catalogGenre.isEmpty ? nil : analysis.catalogGenre,
                year: Int(analysis.catalogYear),
                artworkURL: nil
            )
            return VerificationResult(
                bestMatch: syntheticMatch,
                title:  intelligenceFieldStatus(current: title,  fix: analysis.titleFix),
                artist: intelligenceFieldStatus(current: artist, fix: analysis.artistFix),
                album:  intelligenceFieldStatus(current: album,  fix: analysis.albumFix),
                genre:  intelligenceFieldStatus(current: genre,  fix: analysis.genreFix),
                year:   intelligenceFieldStatus(current: year,   fix: analysis.yearFix)
            )
        }

        // Fallback: fetch from iTunes ourselves and use fuzzy matching
        let results = try await search(title: title, artist: artist)
        let best = results.first(where: { fuzzyMatch($0.title, title) && fuzzyMatch($0.artistName, artist) })
                ?? results.first(where: { fuzzyMatch($0.title, title) })

        guard let match = best else {
            return VerificationResult(
                bestMatch: nil,
                title: .unverifiable, artist: .unverifiable,
                album: .unverifiable, genre: .unverifiable, year: .unverifiable
            )
        }
        return VerificationResult(
            bestMatch: match,
            title:  fieldStatus(current: title,  catalog: match.title),
            artist: fieldStatus(current: artist, catalog: match.artistName),
            album:  albumStatus(current: album,  catalog: match.albumTitle),
            genre:  albumStatus(current: genre,  catalog: match.genre),
            year:   yearStatus(current: year,    catalogYear: match.year)
        )
    }

    // MARK: - Search

    static func search(title: String, artist: String) async throws -> [Result] {
        let term = [title, artist].filter { !$0.isEmpty }.joined(separator: " ")
        guard !term.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "15"),
        ]

        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let response = try JSONDecoder().decode(iTunesResponse.self, from: data)
        let cal = Calendar.current

        return response.results.map { item in
            let year = item.releaseDate.flatMap {
                cal.dateComponents([.year], from: iso8601(from: $0) ?? .distantPast).year
            }
            return Result(
                id: item.trackId,
                title: item.trackName,
                artistName: item.artistName,
                albumTitle: item.collectionName,
                genre: item.primaryGenreName,
                year: year,
                artworkURL: item.artworkUrl100.flatMap(URL.init)
            )
        }
    }

    // MARK: - Helpers

    private static func intelligenceFieldStatus(current: String, fix: String) -> FieldStatus {
        if !fix.isEmpty { return .mismatch(suggested: fix) }
        return current.isEmpty ? .unverifiable : .confirmed
    }

    private static func normalized(_ s: String) -> String {
        s.lowercased()
            .folding(options: [.diacriticInsensitive, .widthInsensitive], locale: .current)
            .filter { $0.isLetter || $0.isNumber || $0.isWhitespace }
            .trimmingCharacters(in: .whitespaces)
    }

    private static func fuzzyMatch(_ a: String, _ b: String) -> Bool {
        let na = normalized(a), nb = normalized(b)
        guard !na.isEmpty, !nb.isEmpty else { return false }
        return na == nb || na.contains(nb) || nb.contains(na)
    }

    private static func fieldStatus(current: String, catalog: String) -> FieldStatus {
        guard !current.isEmpty else { return .unverifiable }
        if fuzzyMatch(current, catalog) { return .confirmed }
        return .mismatch(suggested: catalog)
    }

    private static func albumStatus(current: String, catalog: String?) -> FieldStatus {
        guard let catalog, !catalog.isEmpty else { return .unverifiable }
        return fieldStatus(current: current, catalog: catalog)
    }

    private static func yearStatus(current: String, catalogYear: Int?) -> FieldStatus {
        guard let catalogYear else { return .unverifiable }
        guard !current.isEmpty else { return .unverifiable }
        if current == String(catalogYear) { return .confirmed }
        return .mismatch(suggested: String(catalogYear))
    }

    private static func iso8601(from string: String) -> Date? {
        let fmt = ISO8601DateFormatter()
        fmt.formatOptions = [.withInternetDateTime]
        return fmt.date(from: string)
    }

    // MARK: - Decodable response types

    private struct iTunesResponse: Decodable {
        let results: [iTunesSong]
    }

    private struct iTunesSong: Decodable {
        let trackId: Int
        let trackName: String
        let artistName: String
        let collectionName: String?
        let primaryGenreName: String?
        let releaseDate: String?
        let artworkUrl100: String?
    }
}
