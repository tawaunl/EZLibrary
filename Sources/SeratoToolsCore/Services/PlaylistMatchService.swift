import Foundation

public enum PlaylistMatchService {
    public struct PlaylistEntry: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let title: String
        public let artist: String
        public let sourceLine: String

        public init(id: UUID = UUID(), title: String, artist: String, sourceLine: String) {
            self.id = id
            self.title = title
            self.artist = artist
            self.sourceLine = sourceLine
        }
    }

    public struct PlanItem: Identifiable, Hashable, Sendable {
        public let id: UUID
        public let entry: PlaylistEntry

        public init(id: UUID = UUID(), entry: PlaylistEntry) {
            self.id = id
            self.entry = entry
        }
    }

    public struct MatchResult: Sendable {
        public let matchedTracks: [Track]
        public let planItems: [PlanItem]
    }

    public enum MatchError: LocalizedError {
        case emptyInput
        case noPlaylistRowsDetected
        case spotifyFetchFailed(String)
        case spotifyParseFailed
        case noMatchedTracks

        public var errorDescription: String? {
            switch self {
            case .emptyInput:
                return "Paste a Spotify playlist link, text list, or CSV input first."
            case .noPlaylistRowsDetected:
                return "Couldn't detect any tracks in the pasted input."
            case let .spotifyFetchFailed(message):
                return "Couldn't load the Spotify playlist page: \(message)"
            case .spotifyParseFailed:
                return "Couldn't parse tracks from the Spotify playlist page."
            case .noMatchedTracks:
                return "No playlist tracks matched your Serato library."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .emptyInput:
                return "Paste one playlist URL or a track list, then run PlaylistMatch again."
            case .noPlaylistRowsDetected:
                return "Try CSV format like 'Title,Artist' or lines like 'Artist - Title'."
            case .spotifyFetchFailed:
                return "Check the link and network access, then retry."
            case .spotifyParseFailed:
                return "Paste the playlist as text or CSV input and try again."
            case .noMatchedTracks:
                return "Review the Plan section and update your library with missing tracks."
            }
        }
    }

    public static func resolveEntries(from input: String, session: URLSession = .shared) async throws -> [PlaylistEntry] {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MatchError.emptyInput
        }

        if let spotifyURL = spotifyPlaylistURL(from: trimmed), shouldPreferSpotifyFetch(for: trimmed) {
            let fromSpotify = try await loadSpotifyPlaylistEntries(from: spotifyURL, session: session)
            guard !fromSpotify.isEmpty else {
                throw MatchError.spotifyParseFailed
            }
            return fromSpotify
        }

        let parsed = parseEntries(from: trimmed)
        guard !parsed.isEmpty else {
            throw MatchError.noPlaylistRowsDetected
        }
        return parsed
    }

    public static func match(entries: [PlaylistEntry], libraryTracks: [Track]) -> MatchResult {
        var exactLookup: [String: [Track]] = [:]
        var titleLookup: [String: [Track]] = [:]

        for track in libraryTracks {
            let title = normalizedTitle(track.title)
            let artist = normalizedArtist(track.artist)
            guard !title.isEmpty else { continue }
            exactLookup["\(title)|\(artist)", default: []].append(track)
            titleLookup[title, default: []].append(track)
        }

        var matched: [Track] = []
        var matchedIDs = Set<UUID>()
        var plan: [PlanItem] = []

        for entry in entries {
            let entryTitle = normalizedTitle(entry.title)
            let entryArtist = normalizedArtist(entry.artist)
            guard !entryTitle.isEmpty else {
                plan.append(PlanItem(entry: entry))
                continue
            }

            let exactKey = "\(entryTitle)|\(entryArtist)"
            if let exact = exactLookup[exactKey]?.first {
                if matchedIDs.insert(exact.id).inserted {
                    matched.append(exact)
                }
                continue
            }

            if let titleCandidates = titleLookup[entryTitle] {
                if let artistAligned = titleCandidates.first(where: { candidate in
                    let candidateArtist = normalizedArtist(candidate.artist)
                    if entryArtist.isEmpty || candidateArtist.isEmpty {
                        return true
                    }
                    return candidateArtist.contains(entryArtist) || entryArtist.contains(candidateArtist)
                }) {
                    if matchedIDs.insert(artistAligned.id).inserted {
                        matched.append(artistAligned)
                    }
                    continue
                }

                if let first = titleCandidates.first {
                    if matchedIDs.insert(first.id).inserted {
                        matched.append(first)
                    }
                    continue
                }
            }

            if let fuzzy = fuzzyFind(entry: entry, in: libraryTracks) {
                if matchedIDs.insert(fuzzy.id).inserted {
                    matched.append(fuzzy)
                }
            } else {
                plan.append(PlanItem(entry: entry))
            }
        }

        return MatchResult(matchedTracks: matched, planItems: plan)
    }

    public static func createCrateFromMatches(
        crateName: String,
        matchedTracks: [Track],
        subcratesDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> URL {
        guard !matchedTracks.isEmpty else {
            throw MatchError.noMatchedTracks
        }

        let cleanedName = sanitizedCrateName(crateName)
        let finalName = uniqueCrateName(baseName: cleanedName, subcratesDirectory: subcratesDirectory, fileManager: fileManager)
        let crateURL = subcratesDirectory
            .appendingPathComponent(finalName)
            .appendingPathExtension("crate")

        let trackPaths = uniquePreservingOrder(matchedTracks.map(\.seratoStoredPath))
        let data = SeratoCrateWriter.makeCrateData(trackPaths: trackPaths)
        try AtomicFileWriter.write(data, to: crateURL)
        return crateURL
    }

    public static func parseEntries(from input: String) -> [PlaylistEntry] {
        let rawLines = input
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        guard !rawLines.isEmpty else { return [] }

        if rawLines.count >= 2 && looksLikeCSVHeader(rawLines[0]) {
            return parseCSVRows(rawLines)
        }

        if rawLines.contains(where: { $0.contains(",") }) {
            let csv = parseCSVRows(rawLines)
            if !csv.isEmpty {
                return csv
            }
        }

        return rawLines.compactMap(parsePlainTextLine)
    }

    private static func parseCSVRows(_ lines: [String]) -> [PlaylistEntry] {
        guard !lines.isEmpty else { return [] }

        let headerColumns = splitCSVLine(lines[0]).map(lowercaseTrimmed)
        let hasHeader = looksLikeCSVHeader(lines[0])
        let rows = hasHeader ? Array(lines.dropFirst()) : lines

        let titleIndex = hasHeader ? indexForTitleColumn(in: headerColumns) : 0
        let artistIndex = hasHeader ? indexForArtistColumn(in: headerColumns) : 1

        return rows.compactMap { row in
            let columns = splitCSVLine(row)
            guard !columns.isEmpty else { return nil }

            let title = value(at: titleIndex, in: columns)
            let artist = value(at: artistIndex, in: columns)
            let fallbackTitle = columns.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let resolvedTitle = title.isEmpty ? fallbackTitle : title
            guard !resolvedTitle.isEmpty else { return nil }
            return PlaylistEntry(title: resolvedTitle, artist: artist, sourceLine: row)
        }
    }

    private static func parsePlainTextLine(_ line: String) -> PlaylistEntry? {
        let cleaned = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return nil }

        if cleaned.lowercased().hasPrefix("http://") || cleaned.lowercased().hasPrefix("https://") {
            return nil
        }

        if cleaned.contains(" - ") {
            let pieces = cleaned.components(separatedBy: " - ")
            if pieces.count >= 2 {
                let artist = pieces.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = pieces.dropFirst().joined(separator: " - ").trimmingCharacters(in: .whitespacesAndNewlines)
                if !title.isEmpty {
                    return PlaylistEntry(title: title, artist: artist, sourceLine: line)
                }
            }
        }

        if let byRange = cleaned.range(of: " by ", options: [.caseInsensitive]) {
            let title = cleaned[..<byRange.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
            let artist = cleaned[byRange.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
            if !title.isEmpty {
                return PlaylistEntry(title: title, artist: artist, sourceLine: line)
            }
        }

        return PlaylistEntry(title: cleaned, artist: "", sourceLine: line)
    }

    public static func spotifyPlaylistURL(from input: String) -> URL? {
        if let id = playlistID(fromSpotifyURI: input) {
            return canonicalSpotifyPlaylistURL(for: id)
        }

        let detectorTypes = NSTextCheckingResult.CheckingType.link.rawValue
        guard let detector = try? NSDataDetector(types: detectorTypes) else {
            return spotifyPlaylistURLFromRegex(in: input)
        }

        let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
        var fallbackURL: URL?
        detector.enumerateMatches(in: input, options: [], range: nsRange) { result, _, stop in
            guard let detected = result?.url else { return }
            let cleaned = cleanedCandidateURLString(detected.absoluteString)
            guard let url = URL(string: cleaned) else { return }
            if let playlist = playlistID(fromSpotifyWebURL: url) {
                fallbackURL = canonicalSpotifyPlaylistURL(for: playlist)
                stop.pointee = true
            }
        }

        if let fallbackURL {
            return fallbackURL
        }

        return spotifyPlaylistURLFromRegex(in: input)
    }

    private static func shouldPreferSpotifyFetch(for input: String) -> Bool {
        let parsed = parseEntries(from: input)
        if parsed.isEmpty {
            return true
        }

        // If all parsed entries are actually URL-looking lines, prefer web fetch.
        return parsed.allSatisfy { entry in
            let lowered = entry.title.lowercased()
            return lowered.hasPrefix("http://") || lowered.hasPrefix("https://") || lowered.hasPrefix("spotify:")
        }
    }

    private static func spotifyPlaylistURLFromRegex(in input: String) -> URL? {
        if let id = playlistID(fromSpotifyURI: input) {
            return canonicalSpotifyPlaylistURL(for: id)
        }

        let pattern = #"https?://(?:open|play)\.spotify\.com/(?:(?:embed/)?)playlist/([A-Za-z0-9]{10,})(?:\?[^\s\]\)\>\"']*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = regex.firstMatch(in: input, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let idRange = Range(match.range(at: 1), in: input) else {
            return nil
        }

        return canonicalSpotifyPlaylistURL(for: String(input[idRange]))
    }

    private static func playlistID(fromSpotifyURI input: String) -> String? {
        let pattern = #"spotify:playlist:([A-Za-z0-9]{10,})"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsRange = NSRange(input.startIndex..<input.endIndex, in: input)
        guard let match = regex.firstMatch(in: input, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let idRange = Range(match.range(at: 1), in: input) else {
            return nil
        }

        return String(input[idRange])
    }

    private static func playlistID(fromSpotifyWebURL url: URL) -> String? {
        guard let host = url.host?.lowercased(), host.contains("spotify.com") else {
            return nil
        }

        let pathComponents = url.path
            .split(separator: "/")
            .map(String.init)

        guard !pathComponents.isEmpty else { return nil }

        // Supported examples:
        // /playlist/{id}
        // /embed/playlist/{id}
        // /user/{user}/playlist/{id}
        if let playlistIndex = pathComponents.firstIndex(of: "playlist"), playlistIndex + 1 < pathComponents.count {
            return sanitizeSpotifyID(pathComponents[playlistIndex + 1])
        }

        return nil
    }

    private static func canonicalSpotifyPlaylistURL(for playlistID: String) -> URL? {
        let id = sanitizeSpotifyID(playlistID)
        guard !id.isEmpty else { return nil }
        return URL(string: "https://open.spotify.com/playlist/\(id)")
    }

    private static func sanitizeSpotifyID(_ rawID: String) -> String {
        let cleaned = cleanedCandidateURLString(rawID)
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9]{10,}"#, options: []) else {
            return ""
        }
        let nsRange = NSRange(cleaned.startIndex..<cleaned.endIndex, in: cleaned)
        guard let match = regex.firstMatch(in: cleaned, options: [], range: nsRange),
              let range = Range(match.range, in: cleaned) else {
            return ""
        }
        return String(cleaned[range])
    }

    private static func cleanedCandidateURLString(_ value: String) -> String {
        value.trimmingCharacters(in: CharacterSet(charactersIn: " \n\t\r\"'<>[](){}.,;"))
    }

    private static func loadSpotifyPlaylistEntries(from url: URL, session: URLSession) async throws -> [PlaylistEntry] {
        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw MatchError.spotifyFetchFailed("HTTP \(http.statusCode)")
            }

            guard let html = String(data: data, encoding: .utf8) else {
                throw MatchError.spotifyParseFailed
            }

            return parseSpotifyHTML(html)
        } catch let error as MatchError {
            throw error
        } catch {
            throw MatchError.spotifyFetchFailed(error.localizedDescription)
        }
    }

    private static func parseSpotifyHTML(_ html: String) -> [PlaylistEntry] {
        let blockPattern = #"spotify:track:[^"]+"#
        guard let blockRegex = try? NSRegularExpression(pattern: blockPattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsRange = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = blockRegex.matches(in: html, options: [], range: nsRange)
        guard !matches.isEmpty else { return [] }

        var entries: [PlaylistEntry] = []
        var seen = Set<String>()

        for match in matches {
            guard let range = Range(match.range, in: html) else { continue }
            let index = html.distance(from: html.startIndex, to: range.lowerBound)

            let startOffset = max(0, index - 500)
            let endOffset = min(html.count, index + 900)
            let window = substring(html, from: startOffset, to: endOffset)

            guard let title = firstCapture(in: window, pattern: #""name":"([^"]{1,180})""#) else { continue }
            let artist =
                firstCapture(in: window, pattern: #""profile":\{"name":"([^"]{1,180})""#) ??
                firstCapture(in: window, pattern: #""artists":\{"items":\[\{"name":"([^"]{1,180})""#) ??
                ""

            let cleanedTitle = unescapeJSONLikeString(title)
            let cleanedArtist = unescapeJSONLikeString(artist)
            let key = "\(cleanedTitle.lowercased())|\(cleanedArtist.lowercased())"

            guard !cleanedTitle.isEmpty, seen.insert(key).inserted else { continue }
            entries.append(PlaylistEntry(title: cleanedTitle, artist: cleanedArtist, sourceLine: urlSafeSourceLine(title: cleanedTitle, artist: cleanedArtist)))
        }

        return entries
    }

    private static func urlSafeSourceLine(title: String, artist: String) -> String {
        if artist.isEmpty {
            return title
        }
        return "\(artist) - \(title)"
    }

    private static func firstCapture(in source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        guard let match = regex.firstMatch(in: source, options: [], range: nsRange),
              match.numberOfRanges > 1,
              let captureRange = Range(match.range(at: 1), in: source) else {
            return nil
        }

        return String(source[captureRange])
    }

    private static func substring(_ source: String, from startOffset: Int, to endOffset: Int) -> String {
        guard startOffset < endOffset,
              let start = source.index(source.startIndex, offsetBy: startOffset, limitedBy: source.endIndex),
              let end = source.index(source.startIndex, offsetBy: endOffset, limitedBy: source.endIndex),
              start < end else {
            return ""
        }
        return String(source[start..<end])
    }

    private static func lowercaseTrimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private static func looksLikeCSVHeader(_ line: String) -> Bool {
        let columns = splitCSVLine(line).map(lowercaseTrimmed)
        guard !columns.isEmpty else { return false }
        let hasTitle = columns.contains { $0 == "title" || $0 == "track" || $0 == "song" }
        let hasArtist = columns.contains { $0 == "artist" || $0 == "artists" }
        return hasTitle && hasArtist
    }

    private static func indexForTitleColumn(in columns: [String]) -> Int {
        if let index = columns.firstIndex(where: { $0 == "title" || $0 == "track" || $0 == "song" }) {
            return index
        }
        return 0
    }

    private static func indexForArtistColumn(in columns: [String]) -> Int {
        if let index = columns.firstIndex(where: { $0 == "artist" || $0 == "artists" }) {
            return index
        }
        return 1
    }

    private static func splitCSVLine(_ line: String) -> [String] {
        var output: [String] = []
        var current = ""
        var isInsideQuotes = false

        for char in line {
            if char == "\"" {
                isInsideQuotes.toggle()
                continue
            }
            if char == "," && !isInsideQuotes {
                output.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
                current = ""
                continue
            }
            current.append(char)
        }

        output.append(current.trimmingCharacters(in: .whitespacesAndNewlines))
        return output
    }

    private static func value(at index: Int, in columns: [String]) -> String {
        guard index >= 0 && index < columns.count else { return "" }
        return columns[index].trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedTitle(_ value: String) -> String {
        normalized(value)
            .replacingOccurrences(of: #"\b(original mix|extended mix|radio edit|clean|dirty|intro|outro|official)\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedArtist(_ value: String) -> String {
        normalized(value)
            .replacingOccurrences(of: #"\b(feat|featuring|ft)\.?\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        let replaced = folded.replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
        return replaced.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func fuzzyFind(entry: PlaylistEntry, in libraryTracks: [Track]) -> Track? {
        let entryTitle = normalizedTitle(entry.title)
        let entryArtist = normalizedArtist(entry.artist)
        guard !entryTitle.isEmpty else { return nil }

        return libraryTracks.first(where: { track in
            let title = normalizedTitle(track.title)
            let artist = normalizedArtist(track.artist)

            if title.isEmpty {
                return false
            }

            let titleClose = title.contains(entryTitle) || entryTitle.contains(title)
            if !titleClose {
                return false
            }

            if entryArtist.isEmpty || artist.isEmpty {
                return true
            }

            return artist.contains(entryArtist) || entryArtist.contains(artist)
        })
    }

    private static func sanitizedCrateName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let fallback = trimmed.isEmpty ? "PlaylistMatch" : trimmed
        return fallback
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "\\", with: "-")
    }

    private static func uniqueCrateName(baseName: String, subcratesDirectory: URL, fileManager: FileManager) -> String {
        var candidate = baseName
        var suffix = 2
        while fileManager.fileExists(atPath: subcratesDirectory.appendingPathComponent(candidate).appendingPathExtension("crate").path) {
            candidate = "\(baseName) (\(suffix))"
            suffix += 1
        }
        return candidate
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            if seen.insert(value).inserted {
                output.append(value)
            }
        }
        return output
    }

    private static func unescapeJSONLikeString(_ value: String) -> String {
        var output = value
        output = output.replacingOccurrences(of: "\\u0026", with: "&")
        output = output.replacingOccurrences(of: "\\u0027", with: "'")
        output = output.replacingOccurrences(of: "\\u2019", with: "'")
        output = output.replacingOccurrences(of: "\\\"", with: "\"")
        return output.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}