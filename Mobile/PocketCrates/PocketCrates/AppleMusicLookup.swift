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
