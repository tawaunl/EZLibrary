import Foundation

public enum PlaylistMatchService {
    public struct ParserDiagnostics: Sendable {
        public let apiEntriesCount: Int
        public let htmlEntriesCount: Int
        public let embedEntriesCount: Int
        public let chosenSource: String
        public let chosenEntriesCount: Int
        public let chosenRowsWithArtistCount: Int

        public init(
            apiEntriesCount: Int,
            htmlEntriesCount: Int,
            embedEntriesCount: Int,
            chosenSource: String,
            chosenEntriesCount: Int,
            chosenRowsWithArtistCount: Int
        ) {
            self.apiEntriesCount = apiEntriesCount
            self.htmlEntriesCount = htmlEntriesCount
            self.embedEntriesCount = embedEntriesCount
            self.chosenSource = chosenSource
            self.chosenEntriesCount = chosenEntriesCount
            self.chosenRowsWithArtistCount = chosenRowsWithArtistCount
        }
    }

    public struct ResolvedPlaylist: Sendable {
        public let playlistName: String?
        public let entries: [PlaylistEntry]
        public let diagnostics: ParserDiagnostics?

        public init(playlistName: String?, entries: [PlaylistEntry], diagnostics: ParserDiagnostics? = nil) {
            self.playlistName = playlistName
            self.entries = entries
            self.diagnostics = diagnostics
        }
    }

    public struct PlaylistEntry: Identifiable, Hashable, Sendable, Codable {
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

    public struct PlanItem: Identifiable, Hashable, Sendable, Codable {
        public let id: UUID
        public let entry: PlaylistEntry

        public init(id: UUID = UUID(), entry: PlaylistEntry) {
            self.id = id
            self.entry = entry
        }
    }

    public enum MatchReason: String, CaseIterable, Hashable, Sendable, Codable {
        case exactTitleAndArtist
        case exactTitleCloseArtist
        case exactTitleOnly
        case fuzzyTitleArtist

        public var displayName: String {
            switch self {
            case .exactTitleAndArtist:
                return "Exact title + artist"
            case .exactTitleCloseArtist:
                return "Exact title + close artist"
            case .exactTitleOnly:
                return "Exact title only"
            case .fuzzyTitleArtist:
                return "Fuzzy title/artist"
            }
        }
    }

    public enum MatchConfidence: String, CaseIterable, Hashable, Sendable, Codable {
        case high
        case medium
        case low

        public var displayName: String {
            rawValue.capitalized
        }
    }

    public struct MatchedEntry: Identifiable, Hashable, Sendable {
        public var id: UUID { entry.id }

        public let entry: PlaylistEntry
        public let primaryTrack: Track
        public let versions: [Track]
        public let reason: MatchReason
        public let confidence: MatchConfidence

        public init(
            entry: PlaylistEntry,
            primaryTrack: Track,
            versions: [Track],
            reason: MatchReason,
            confidence: MatchConfidence
        ) {
            self.entry = entry
            self.primaryTrack = primaryTrack
            self.versions = versions
            self.reason = reason
            self.confidence = confidence
        }
    }

    public struct MatchResult: Sendable {
        public let matchedEntries: [MatchedEntry]
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

    public enum PlanPersistenceError: LocalizedError {
        case emptyPlan
        case unreadablePlan
        case invalidPlanFormat

        public var errorDescription: String? {
            switch self {
            case .emptyPlan:
                return "There are no plan items to save."
            case .unreadablePlan:
                return "Couldn't read the selected plan file."
            case .invalidPlanFormat:
                return "That file is not a valid PlaylistMatch plan."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .emptyPlan:
                return "Run PlaylistMatch first so unmatched tracks appear in Plan."
            case .unreadablePlan:
                return "Check file permissions and try loading again."
            case .invalidPlanFormat:
                return "Load a .playlistmatch-plan.json file created by PlaylistMatch."
            }
        }
    }

    private struct PlanFile: Codable {
        let version: Int
        let createdAt: Date
        let items: [PlanItem]
    }

    public static func resolveEntries(from input: String, session: URLSession = .shared) async throws -> [PlaylistEntry] {
        let resolved = try await resolvePlaylist(from: input, session: session)
        return resolved.entries
    }

    public static func resolvePlaylist(from input: String, session: URLSession = .shared) async throws -> ResolvedPlaylist {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MatchError.emptyInput
        }

        if let spotifyURL = spotifyPlaylistURL(from: trimmed), shouldPreferSpotifyFetch(for: trimmed) {
            let fromSpotify = try await loadSpotifyPlaylistData(from: spotifyURL, session: session)
            guard !fromSpotify.entries.isEmpty else {
                throw MatchError.spotifyParseFailed
            }
            return fromSpotify
        }

        let parsed = parseEntries(from: trimmed)
        guard !parsed.isEmpty else {
            throw MatchError.noPlaylistRowsDetected
        }
        return ResolvedPlaylist(playlistName: nil, entries: parsed, diagnostics: nil)
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
        var matchedEntries: [MatchedEntry] = []
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
                let versions = libraryVersions(for: entry, selectedTrack: exact, libraryTracks: libraryTracks)
                matchedEntries.append(
                    MatchedEntry(
                        entry: entry,
                        primaryTrack: exact,
                        versions: versions,
                        reason: .exactTitleAndArtist,
                        confidence: .high
                    )
                )
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
                    let versions = libraryVersions(for: entry, selectedTrack: artistAligned, libraryTracks: libraryTracks)
                    matchedEntries.append(
                        MatchedEntry(
                            entry: entry,
                            primaryTrack: artistAligned,
                            versions: versions,
                            reason: .exactTitleCloseArtist,
                            confidence: .high
                        )
                    )
                    if matchedIDs.insert(artistAligned.id).inserted {
                        matched.append(artistAligned)
                    }
                    continue
                }

                if let first = titleCandidates.first {
                    let versions = libraryVersions(for: entry, selectedTrack: first, libraryTracks: libraryTracks)
                    matchedEntries.append(
                        MatchedEntry(
                            entry: entry,
                            primaryTrack: first,
                            versions: versions,
                            reason: .exactTitleOnly,
                            confidence: .medium
                        )
                    )
                    if matchedIDs.insert(first.id).inserted {
                        matched.append(first)
                    }
                    continue
                }
            }

            if let fuzzy = fuzzyFind(entry: entry, in: libraryTracks) {
                let versions = libraryVersions(for: entry, selectedTrack: fuzzy, libraryTracks: libraryTracks)
                matchedEntries.append(
                    MatchedEntry(
                        entry: entry,
                        primaryTrack: fuzzy,
                        versions: versions,
                        reason: .fuzzyTitleArtist,
                        confidence: .low
                    )
                )
                if matchedIDs.insert(fuzzy.id).inserted {
                    matched.append(fuzzy)
                }
            } else {
                plan.append(PlanItem(entry: entry))
            }
        }

        return MatchResult(matchedEntries: matchedEntries, matchedTracks: matched, planItems: plan)
    }

    public static func savePlan(_ planItems: [PlanItem], to fileURL: URL) throws {
        guard !planItems.isEmpty else {
            throw PlanPersistenceError.emptyPlan
        }

        let payload = PlanFile(version: 1, createdAt: Date(), items: planItems)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601

        let data = try encoder.encode(payload)
        try AtomicFileWriter.write(data, to: fileURL)
    }

    public static func loadPlan(from fileURL: URL) throws -> [PlanItem] {
        let data: Data
        do {
            data = try Data(contentsOf: fileURL)
        } catch {
            throw PlanPersistenceError.unreadablePlan
        }

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        do {
            let payload = try decoder.decode(PlanFile.self, from: data)
            return payload.items
        } catch {
            throw PlanPersistenceError.invalidPlanFormat
        }
    }

    private static func libraryVersions(for entry: PlaylistEntry, selectedTrack: Track, libraryTracks: [Track]) -> [Track] {
        let entryTitle = normalizedTitle(entry.title)
        let selectedTitle = normalizedTitle(selectedTrack.title)
        let targetTitle = entryTitle.isEmpty ? selectedTitle : entryTitle

        let entryArtist = normalizedArtist(entry.artist)
        let selectedArtist = normalizedArtist(selectedTrack.artist)
        let targetArtist = entryArtist.isEmpty ? selectedArtist : entryArtist

        let candidates = libraryTracks.filter { candidate in
            let candidateTitle = normalizedTitle(candidate.title)
            guard !candidateTitle.isEmpty else { return false }

            let titleMatches =
                candidateTitle == targetTitle ||
                candidateTitle == selectedTitle ||
                candidateTitle.contains(targetTitle) ||
                targetTitle.contains(candidateTitle) ||
                candidateTitle.contains(selectedTitle) ||
                selectedTitle.contains(candidateTitle)
            guard titleMatches else { return false }

            let candidateArtist = normalizedArtist(candidate.artist)
            if targetArtist.isEmpty || candidateArtist.isEmpty {
                return true
            }

            return candidateArtist.contains(targetArtist) || targetArtist.contains(candidateArtist)
        }

        let deduped = uniqueTracksPreservingOrder(candidates)
        return deduped.sorted {
            let lhs = normalizedTitle($0.title)
            let rhs = normalizedTitle($1.title)
            if lhs == rhs {
                return $0.title.localizedStandardCompare($1.title) == .orderedAscending
            }
            return lhs.localizedStandardCompare(rhs) == .orderedAscending
        }
    }

    private static func uniqueTracksPreservingOrder(_ tracks: [Track]) -> [Track] {
        var seen = Set<String>()
        var output: [Track] = []
        for track in tracks {
            let key = track.seratoStoredPath
            if seen.insert(key).inserted {
                output.append(track)
            }
        }
        return output
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

    private static func loadSpotifyPlaylistData(from url: URL, session: URLSession) async throws -> ResolvedPlaylist {
        let oEmbedName = try? await fetchSpotifyPlaylistNameViaOEmbed(url: url, session: session)
        var apiEntriesCount = 0
        var htmlEntriesCount = 0
        var embedEntriesCount = 0

        if let playlistID = playlistID(fromSpotifyWebURL: url),
           let apiEntries = try? await loadSpotifyPlaylistEntriesViaWebAPI(playlistID: playlistID, session: session),
           !apiEntries.isEmpty {
            apiEntriesCount = apiEntries.count
            let diagnostics = ParserDiagnostics(
                apiEntriesCount: apiEntriesCount,
                htmlEntriesCount: htmlEntriesCount,
                embedEntriesCount: embedEntriesCount,
                chosenSource: "spotify-web-api",
                chosenEntriesCount: apiEntries.count,
                chosenRowsWithArtistCount: apiEntries.filter { !$0.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            )
            return ResolvedPlaylist(playlistName: oEmbedName, entries: apiEntries, diagnostics: diagnostics)
        }

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

                let htmlEntries = parseSpotifyHTML(html)
                htmlEntriesCount = htmlEntries.count
            var allCandidates: [[PlaylistEntry]] = [htmlEntries]
                var candidateNames: [String] = ["main-html"]

            if let playlistID = playlistID(fromSpotifyWebURL: url),
               let embedURL = URL(string: "https://open.spotify.com/embed/playlist/\(playlistID)") {
                var embedRequest = URLRequest(url: embedURL)
                embedRequest.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                if let (embedData, embedResponse) = try? await session.data(for: embedRequest),
                   let http = embedResponse as? HTTPURLResponse,
                   (200...299).contains(http.statusCode),
                   let embedHTML = String(data: embedData, encoding: .utf8) {
                    let embedEntries = parseSpotifyHTML(embedHTML)
                    if !embedEntries.isEmpty {
                        allCandidates.append(embedEntries)
                        candidateNames.append("embed-html")
                        embedEntriesCount = embedEntries.count
                    }
                }

                if var nd1Components = URLComponents(url: url, resolvingAgainstBaseURL: false) {
                    var queryItems = nd1Components.queryItems ?? []
                    queryItems.removeAll { $0.name == "nd" }
                    queryItems.append(URLQueryItem(name: "nd", value: "1"))
                    nd1Components.queryItems = queryItems

                    if let nd1URL = nd1Components.url {
                        var nd1Request = URLRequest(url: nd1URL)
                        nd1Request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")
                        if let (nd1Data, nd1Response) = try? await session.data(for: nd1Request),
                           let http = nd1Response as? HTTPURLResponse,
                           (200...299).contains(http.statusCode),
                           let nd1HTML = String(data: nd1Data, encoding: .utf8) {
                            let nd1Entries = parseSpotifyHTML(nd1HTML)
                            if !nd1Entries.isEmpty {
                                allCandidates.append(nd1Entries)
                                candidateNames.append("main-html-nd1")
                            }
                        }
                    }
                }
            }

            var bestIndex = 0
            var bestScore = Int.min
            for (index, candidate) in allCandidates.enumerated() {
                let score = candidateScore(candidate)
                if score > bestScore {
                    bestScore = score
                    bestIndex = index
                }
            }
            let bestEntries = allCandidates[bestIndex]
            let chosenSource = candidateNames.indices.contains(bestIndex) ? candidateNames[bestIndex] : "main-html"
            let htmlName = extractSpotifyPlaylistName(fromHTML: html)
            let diagnostics = ParserDiagnostics(
                apiEntriesCount: apiEntriesCount,
                htmlEntriesCount: htmlEntriesCount,
                embedEntriesCount: embedEntriesCount,
                chosenSource: chosenSource,
                chosenEntriesCount: bestEntries.count,
                chosenRowsWithArtistCount: bestEntries.filter { !$0.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
            )
            return ResolvedPlaylist(
                playlistName: oEmbedName ?? htmlName,
                entries: bestEntries,
                diagnostics: diagnostics
            )
        } catch let error as MatchError {
            throw error
        } catch {
            throw MatchError.spotifyFetchFailed(error.localizedDescription)
        }
    }

    private static func fetchSpotifyPlaylistNameViaOEmbed(url: URL, session: URLSession) async throws -> String {
        guard var components = URLComponents(string: "https://open.spotify.com/oembed") else {
            throw MatchError.spotifyParseFailed
        }
        components.queryItems = [
            URLQueryItem(name: "url", value: url.absoluteString)
        ]
        guard let endpoint = components.url else {
            throw MatchError.spotifyParseFailed
        }

        var request = URLRequest(url: endpoint)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MatchError.spotifyFetchFailed("Spotify oEmbed HTTP \(http.statusCode)")
        }

        let decoded = try JSONDecoder().decode(SpotifyOEmbedResponse.self, from: data)
        return decoded.title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func loadSpotifyPlaylistEntriesViaWebAPI(playlistID: String, session: URLSession) async throws -> [PlaylistEntry] {
        let token = try await fetchSpotifyWebAccessToken(session: session)
        guard !token.isEmpty else {
            throw MatchError.spotifyParseFailed
        }

        var entries: [PlaylistEntry] = []
        var seen = Set<String>()
        var nextURLString: String? = "https://api.spotify.com/v1/playlists/\(playlistID)/tracks?limit=100"

        while let currentURLString = nextURLString, let endpoint = URL(string: currentURLString) {
            var request = URLRequest(url: endpoint)
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                throw MatchError.spotifyFetchFailed("Spotify API HTTP \(http.statusCode)")
            }

            let decoded: SpotifyPlaylistTracksResponse
            do {
                decoded = try JSONDecoder().decode(SpotifyPlaylistTracksResponse.self, from: data)
            } catch {
                throw MatchError.spotifyParseFailed
            }

            for item in decoded.items {
                guard let track = item.track else { continue }
                let title = track.name.trimmingCharacters(in: .whitespacesAndNewlines)
                let artist = track.artists.first?.name.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !title.isEmpty else { continue }

                let key = "\(title.lowercased())|\(artist.lowercased())"
                if seen.insert(key).inserted {
                    entries.append(PlaylistEntry(title: title, artist: artist, sourceLine: urlSafeSourceLine(title: title, artist: artist)))
                }
            }

            nextURLString = decoded.next
        }

        return entries
    }

    private static func fetchSpotifyWebAccessToken(session: URLSession) async throws -> String {
        guard let url = URL(string: "https://open.spotify.com/get_access_token?reason=transport&productType=web_player") else {
            throw MatchError.spotifyParseFailed
        }

        var request = URLRequest(url: url)
        request.setValue("Mozilla/5.0", forHTTPHeaderField: "User-Agent")

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw MatchError.spotifyFetchFailed("Spotify token HTTP \(http.statusCode)")
        }

        let decoded: SpotifyWebTokenResponse
        do {
            decoded = try JSONDecoder().decode(SpotifyWebTokenResponse.self, from: data)
        } catch {
            throw MatchError.spotifyParseFailed
        }

        return decoded.accessToken.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private struct SpotifyWebTokenResponse: Decodable {
        let accessToken: String

        private enum CodingKeys: String, CodingKey {
            case accessToken = "accessToken"
        }
    }

    private struct SpotifyPlaylistTracksResponse: Decodable {
        let items: [SpotifyPlaylistTrackItem]
        let next: String?
    }

    private struct SpotifyPlaylistTrackItem: Decodable {
        let track: SpotifyTrack?
    }

    private struct SpotifyTrack: Decodable {
        let name: String
        let artists: [SpotifyArtist]
    }

    private struct SpotifyArtist: Decodable {
        let name: String
    }

    private struct SpotifyOEmbedResponse: Decodable {
        let title: String
    }

    private static func parseSpotifyHTML(_ html: String) -> [PlaylistEntry] {
        var candidateSets: [[PlaylistEntry]] = []

        let direct = parseSpotifyTrackWindows(in: html, escapedJSON: false)
        if !direct.isEmpty {
            candidateSets.append(direct)
        }

        let escaped = parseSpotifyTrackWindows(in: html, escapedJSON: true)
        if !escaped.isEmpty {
            candidateSets.append(escaped)
        }

        for decoded in decodeLikelySpotifyBase64Payloads(from: html) {
            let parsed = parseSpotifyTrackWindows(in: decoded, escapedJSON: false)
            if !parsed.isEmpty {
                candidateSets.append(parsed)
            }

            let parsedEscaped = parseSpotifyTrackWindows(in: decoded, escapedJSON: true)
            if !parsedEscaped.isEmpty {
                candidateSets.append(parsedEscaped)
            }
        }

        if let best = candidateSets.max(by: { candidateScore($0) < candidateScore($1) }) {
            return best
        }

        return []
    }

    private static func candidateScore(_ entries: [PlaylistEntry]) -> Int {
        let withArtist = entries.filter { !$0.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.count
        // Prioritize total row count first, then rows with known artists.
        return (entries.count * 1000) + withArtist
    }

    private struct ExtractedSpotifyTrack {
        let title: String
        let artist: String
        let trackNumber: Int?
        let occurrenceIndex: Int
        let uri: String
    }

    private static func parseSpotifyTrackWindows(in source: String, escapedJSON: Bool) -> [PlaylistEntry] {
        let structured = parseSpotifyTrackObjects(in: source, escapedJSON: escapedJSON)
        if !structured.isEmpty {
            return structured
        }

        let trackPattern = escapedJSON
            ? #"spotify:track:[A-Za-z0-9]{10,}"#
            : #"spotify:track:[A-Za-z0-9]{10,}"#

        guard let trackRegex = try? NSRegularExpression(pattern: trackPattern, options: [.caseInsensitive]) else {
            return []
        }

        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = trackRegex.matches(in: source, options: [], range: nsRange)
        guard !matches.isEmpty else { return [] }

        let titlePatterns: [String]
        let artistPatterns: [String]
        if escapedJSON {
            titlePatterns = [
                #"\\"name\\":\\"([^\\"]{1,220})\\",\\"playability\\""#,
                #"\\"name\\":\\"([^\\"]{1,220})\\""#
            ]
            artistPatterns = [
                #"\\"profile\\":\{\\"name\\":\\"([^\\"]{1,180})\\""#,
                #"\\"artists\\":\{\\"items\\":\[\{\\"name\\":\\"([^\\"]{1,180})\\""#,
                #"\\"artists\\":\[\{\\"name\\":\\"([^\\"]{1,180})\\""#
            ]
        } else {
            titlePatterns = [
                #""name":"([^"]{1,220})","playability""#,
                #""name":"([^"]{1,220})""#
            ]
            artistPatterns = [
                #""profile":\{"name":"([^"]{1,180})""#,
                #""artists":\{"items":\[\{"name":"([^"]{1,180})""#,
                #""artists":\[\{"name":"([^"]{1,180})""#
            ]
        }

        var extracted: [ExtractedSpotifyTrack] = []

        for (occurrenceIndex, match) in matches.enumerated() {
            guard let range = Range(match.range, in: source) else { continue }
            let index = source.distance(from: source.startIndex, to: range.lowerBound)
            let uri = String(source[range])

            // Favor metadata immediately preceding the track URI to avoid
            // cross-track title/artist bleed from neighboring objects.
            let startOffset = max(0, index - 2200)
            let endOffset = min(source.count, index + 220)
            let window = substring(source, from: startOffset, to: endOffset)

            let rawTitle = titlePatterns.compactMap { lastCapture(in: window, pattern: $0) }.first ?? ""
            let rawArtist = artistPatterns.compactMap { lastCapture(in: window, pattern: $0) }.first ?? ""
            let rawTrackNumber = lastCapture(in: window, pattern: #""trackNumber":([0-9]{1,3})"#)

            let cleanedTitle = unescapeJSONLikeString(rawTitle)
            let cleanedArtist = unescapeJSONLikeString(rawArtist)
            guard !cleanedTitle.isEmpty else { continue }

            extracted.append(
                ExtractedSpotifyTrack(
                    title: cleanedTitle,
                    artist: cleanedArtist,
                    trackNumber: rawTrackNumber.flatMap(Int.init),
                    occurrenceIndex: occurrenceIndex,
                    uri: uri
                )
            )
        }

        let ordered: [ExtractedSpotifyTrack]
        if extracted.allSatisfy({ $0.trackNumber != nil }) {
            ordered = extracted.sorted {
                let lhs = $0.trackNumber ?? Int.max
                let rhs = $1.trackNumber ?? Int.max
                if lhs == rhs {
                    return $0.occurrenceIndex < $1.occurrenceIndex
                }
                return lhs < rhs
            }
        } else {
            ordered = extracted.sorted { $0.occurrenceIndex < $1.occurrenceIndex }
        }

        var seenURIs = Set<String>()
        var entries: [PlaylistEntry] = []
        entries.reserveCapacity(ordered.count)

        for track in ordered {
            if seenURIs.insert(track.uri).inserted {
                entries.append(
                    PlaylistEntry(
                        title: track.title,
                        artist: track.artist,
                        sourceLine: urlSafeSourceLine(title: track.title, artist: track.artist)
                    )
                )
            }
        }

        return entries
    }

    private static func parseSpotifyTrackObjects(in source: String, escapedJSON: Bool) -> [PlaylistEntry] {
        // Capture artist/title/trackNumber/uri from the same track object block
        // to prevent title-artist cross-association.
        let pattern: String
        if escapedJSON {
            pattern = #"\"artists\":\{\"items\":\[\{\"profile\":\{\"name\":\"([^\"]{1,180})\".*?\"name\":\"([^\"]{1,220})\",\"playability\":\{\"playable\":[^}]+\}.*?\"trackNumber\":([0-9]{1,3}),\"uri\":\"(spotify:track:[A-Za-z0-9]{10,})\""#
        } else {
            pattern = #""artists":\{"items":\[\{"profile":\{"name":"([^"]{1,180})".*?"name":"([^"]{1,220})","playability":\{"playable":[^}]+\}.*?"trackNumber":([0-9]{1,3}),"uri":"(spotify:track:[A-Za-z0-9]{10,})""#
        }

        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, options: [], range: nsRange)
        guard !matches.isEmpty else { return [] }

        struct Row {
            let title: String
            let artist: String
            let trackNumber: Int
            let uri: String
            let index: Int
        }

        var rows: [Row] = []
        rows.reserveCapacity(matches.count)

        for (index, match) in matches.enumerated() {
            guard match.numberOfRanges >= 5,
                  let artistRange = Range(match.range(at: 1), in: source),
                  let titleRange = Range(match.range(at: 2), in: source),
                  let trackNumberRange = Range(match.range(at: 3), in: source),
                  let uriRange = Range(match.range(at: 4), in: source) else {
                continue
            }

            let artist = unescapeJSONLikeString(String(source[artistRange]))
            let title = unescapeJSONLikeString(String(source[titleRange]))
            let trackNumber = Int(String(source[trackNumberRange])) ?? (index + 1)
            let uri = String(source[uriRange])
            guard !title.isEmpty else { continue }

            rows.append(Row(title: title, artist: artist, trackNumber: trackNumber, uri: uri, index: index))
        }

        rows.sort {
            if $0.trackNumber == $1.trackNumber {
                return $0.index < $1.index
            }
            return $0.trackNumber < $1.trackNumber
        }

        var seen = Set<String>()
        var entries: [PlaylistEntry] = []
        entries.reserveCapacity(rows.count)

        for row in rows {
            if seen.insert(row.uri).inserted {
                entries.append(
                    PlaylistEntry(
                        title: row.title,
                        artist: row.artist,
                        sourceLine: urlSafeSourceLine(title: row.title, artist: row.artist)
                    )
                )
            }
        }

        return entries
    }

    private static func decodeLikelySpotifyBase64Payloads(from source: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: #"[A-Za-z0-9+/]{120,}={0,2}"#, options: []) else {
            return []
        }

        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, options: [], range: nsRange)
        guard !matches.isEmpty else { return [] }

        var decodedPayloads: [String] = []
        decodedPayloads.reserveCapacity(min(matches.count, 180))

        for match in matches.prefix(480) {
            guard let range = Range(match.range, in: source) else { continue }
            let candidate = String(source[range])

            // Heuristic: only decode if marker for spotify:track appears in base64 form.
            guard candidate.contains("c3BvdGlmeTp0cmFjaz") else { continue }
            guard let data = decodeBase64Lenient(candidate), data.count > 200 else { continue }
            guard let decoded = String(data: data, encoding: .utf8), decoded.contains("spotify:track:") else { continue }

            decodedPayloads.append(decoded)
            if decodedPayloads.count >= 80 {
                break
            }
        }

        return decodedPayloads
    }

    private static func decodeBase64Lenient(_ value: String) -> Data? {
        let cleaned = value
            .replacingOccurrences(of: "\\n", with: "")
            .replacingOccurrences(of: "\\r", with: "")

        let remainder = cleaned.count % 4
        let padded: String
        if remainder == 0 {
            padded = cleaned
        } else {
            padded = cleaned + String(repeating: "=", count: 4 - remainder)
        }

        return Data(base64Encoded: padded, options: [.ignoreUnknownCharacters])
    }

    private static func extractSpotifyPlaylistName(fromHTML html: String) -> String? {
        guard let rawTitle = firstCapture(in: html, pattern: #"<title>([^<]+)</title>"#) else {
            return nil
        }

        let decoded = unescapeJSONLikeString(rawTitle)
            .replacingOccurrences(of: "| Spotify Playlist", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        return decoded.isEmpty ? nil : decoded
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

    private static func lastCapture(in source: String, pattern: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }

        let nsRange = NSRange(source.startIndex..<source.endIndex, in: source)
        let matches = regex.matches(in: source, options: [], range: nsRange)
        guard let match = matches.last,
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
            // Remove common "featuring" clauses embedded in titles.
            .replacingOccurrences(of: #"\((feat|featuring|ft)\.?[^)]*\)"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\[(feat|featuring|ft)\.?[^\]]*\]"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(feat|featuring|ft)\.?\s+[a-z0-9\s&,'\-]+$"#, with: " ", options: .regularExpression)
            .replacingOccurrences(
                of: #"\b(original mix|extended mix|extended|radio edit|clean|dirty|intro|outro|official|club mix|vip mix|vip|bootleg|rework|remix|mixshow|short edit|long edit|intro edit|main mix|original|version)\b"#,
                with: " ",
                options: .regularExpression
            )
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedArtist(_ value: String) -> String {
        normalized(value)
            .replacingOccurrences(of: #"\b(feat|featuring|ft)\.?\b"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"\b(with|w|x|presents)\b"#, with: " ", options: .regularExpression)
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