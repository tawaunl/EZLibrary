import Foundation
import FoundationModels

// MARK: - iTunes search tool

struct iTunesSearchTool: Tool {
    let name = "searchITunes"
    let description = "Search the iTunes catalog for a music track by artist, title, or both."

    @Generable
    struct Arguments {
        @Guide(description: "Search query, e.g. 'Daft Punk Around the World' or just 'Daft Punk'")
        let query: String
    }

    func call(arguments: Arguments) async throws -> String {
        var components = URLComponents(string: "https://itunes.apple.com/search")!
        components.queryItems = [
            URLQueryItem(name: "term", value: arguments.query),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "limit", value: "5"),
        ]
        let (data, _) = try await URLSession.shared.data(from: components.url!)
        let decoded = try JSONDecoder().decode(SearchResponse.self, from: data)

        guard !decoded.results.isEmpty else {
            return "No results found."
        }
        return decoded.results.enumerated().map { idx, s in
            var line = "[\(idx)] \(s.trackName) — \(s.artistName)"
            if let album = s.collectionName { line += " (\(album))" }
            if let genre = s.primaryGenreName { line += " {genre: \(genre)}" }
            if let date = s.releaseDate { line += " [\(date.prefix(4))]" }
            return line
        }.joined(separator: "\n")
    }

    private struct SearchResponse: Decodable {
        let results: [Song]
        struct Song: Decodable {
            let trackName: String
            let artistName: String
            let collectionName: String?
            let primaryGenreName: String?
            let releaseDate: String?
        }
    }
}

// MARK: - Generable output types

@Generable(description: "Cleaned and completed music track metadata based on existing ID3 tags")
struct TrackMetadataSuggestion {
    @Guide(description: "Song title, properly capitalized. ALWAYS preserve DJ version labels such as Remix, Extended Mix, Club Mix, Dub Mix, Dirty, Clean, Intro, Outro, Instrumental, Acapella, Radio Edit, Original Mix, VIP, Bootleg, Transition, Mashup — even if they differ from the catalog. Empty if no improvement.")
    var title: String

    @Guide(description: "Primary artist name, properly formatted. Empty if no improvement.")
    var artist: String

    @Guide(description: "Album name. Empty if unknown.")
    var album: String

    @Guide(description: "Music genre (e.g. House, Techno, Hip-Hop, R&B). Empty if unknown.")
    var genre: String
}

@Generable(description: "Result of verifying a DJ track's ID3 tags against the iTunes catalog")
struct TagVerificationAnalysis {
    @Guide(description: "True only if a confident catalog match was found for this specific recording — not just a song with the same name.")
    var matchFound: Bool

    @Guide(description: "Catalog song title. Empty if no match.")
    var catalogTitle: String

    @Guide(description: "Catalog artist name. Empty if no match.")
    var catalogArtist: String

    @Guide(description: "Catalog album. Empty if no match or unknown.")
    var catalogAlbum: String

    @Guide(description: "Catalog genre. Empty if no match or unknown.")
    var catalogGenre: String

    @Guide(description: "Catalog release year as 4-digit string. Empty if no match or unknown.")
    var catalogYear: String

    @Guide(description: "Corrected title if the current tag is wrong or poorly formatted, else empty. NEVER remove or alter DJ version labels like Remix, Extended Mix, Club Mix, Dub Mix, Dirty, Clean, Intro, Outro, Instrumental, Acapella, Radio Edit, Original Mix, VIP, Bootleg, or Transition — a title with these is correct by definition.")
    var titleFix: String

    @Guide(description: "Corrected artist if the current tag is wrong, else empty.")
    var artistFix: String

    @Guide(description: "Corrected album if the current tag is wrong, else empty.")
    var albumFix: String

    @Guide(description: "Corrected genre if the current tag is wrong, else empty.")
    var genreFix: String

    @Guide(description: "Corrected year if the current tag is wrong, else empty.")
    var yearFix: String
}

// MARK: -

enum IntelligenceLookup {
    enum LookupError: Error, LocalizedError {
        case notAvailable(SystemLanguageModel.Availability.UnavailableReason?)

        var errorDescription: String? {
            switch self {
            case .notAvailable(.deviceNotEligible):
                return "Apple Intelligence requires a compatible device."
            case .notAvailable(.appleIntelligenceNotEnabled):
                return "Enable Apple Intelligence in Settings to use this feature."
            case .notAvailable(.modelNotReady):
                return "Apple Intelligence is still downloading. Try again shortly."
            default:
                return "Apple Intelligence is not available."
            }
        }
    }

    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    // MARK: - Auto-fill suggestion (with iTunes tool calling)

    static func suggest(
        title: String,
        artist: String,
        album: String,
        genre: String,
        comment: String,
        year: String
    ) async throws -> TrackMetadataSuggestion {
        try requireAvailable()

        var tagLines: [String] = []
        if !title.isEmpty   { tagLines.append("Title: \(title)") }
        if !artist.isEmpty  { tagLines.append("Artist: \(artist)") }
        if !album.isEmpty   { tagLines.append("Album: \(album)") }
        if !genre.isEmpty   { tagLines.append("Genre: \(genre)") }
        if !comment.isEmpty { tagLines.append("Comment: \(comment)") }
        if !year.isEmpty    { tagLines.append("Year: \(year)") }
        let tagSummary = tagLines.isEmpty ? "(no existing tags)" : tagLines.joined(separator: "\n")

        let session = LanguageModelSession(
            tools: [iTunesSearchTool()],
            instructions: """
            You help clean up ID3 tags for DJ music tracks. \
            Use the searchITunes tool to look up the correct metadata when the tags look incomplete, \
            typo-ridden, or ambiguous. Strip DJ version labels (Remix, Extended Mix, Dirty, Intro, etc.) \
            from the title ONLY when constructing the search query — never remove them from the returned title. \
            DJ version labels in a title are always intentional and correct; do not alter them. \
            Return empty strings for fields you can't determine with confidence.
            """
        )

        let prompt = """
        Clean up and complete these ID3 tags for a DJ track:
        \(tagSummary)
        """

        return try await session.respond(to: prompt, generating: TrackMetadataSuggestion.self).content
    }

    // MARK: - Tag verification (with iTunes tool calling)

    /// Uses the on-device model with iTunes tool calling to verify a track's tags.
    /// Returns `nil` if Apple Intelligence is unavailable — callers should fall back to fuzzy matching.
    static func verify(
        title: String,
        artist: String,
        album: String,
        genre: String,
        year: String
    ) async -> TagVerificationAnalysis? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }

        var tagLines: [String] = []
        if !title.isEmpty  { tagLines.append("Title: \(title)") }
        if !artist.isEmpty { tagLines.append("Artist: \(artist)") }
        if !album.isEmpty  { tagLines.append("Album: \(album)") }
        if !genre.isEmpty  { tagLines.append("Genre: \(genre)") }
        if !year.isEmpty   { tagLines.append("Year: \(year)") }
        let tagSummary = tagLines.isEmpty ? "(no existing tags)" : tagLines.joined(separator: "\n")

        let session = LanguageModelSession(
            tools: [iTunesSearchTool()],
            instructions: """
            You verify ID3 tags for DJ music tracks by searching the iTunes catalog. \
            Strip DJ version labels (Remix, Extended Mix, Club Mix, Dirty, Intro, Outro, VIP, Bootleg, etc.) \
            from the title ONLY when constructing the search query — never flag them as errors in titleFix. \
            A title like "Around the World (Daft Punk Extended Mix)" is correct if it contains that version; \
            do not suggest removing the version label. Only set matchFound = true if confident the catalog \
            result matches this specific recording. Report catalog values and corrections for genuinely wrong \
            fields (typos, wrong artist, wrong year). Return empty strings for unknown or already-correct fields.
            """
        )

        let prompt = """
        Verify these ID3 tags against the iTunes catalog:
        \(tagSummary)
        """

        return try? await session.respond(to: prompt, generating: TagVerificationAnalysis.self).content
    }

    // MARK: - Helpers

    private static func requireAvailable() throws {
        let model = SystemLanguageModel.default
        if case .available = model.availability { return }
        if case let .unavailable(reason) = model.availability {
            throw LookupError.notAvailable(reason)
        }
        throw LookupError.notAvailable(nil)
    }
}
