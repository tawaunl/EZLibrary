import Foundation

/// Finds where a track can actually be *bought* before the PlaylistMatch flow
/// falls back to a YouTube rip. A store is only ever returned when it genuinely
/// lists the track:
/// - iTunes is resolved through the public Search API (direct product link).
/// - Beatport is resolved by reading the `__NEXT_DATA__` JSON embedded in its
///   search page and matching the track/artist, then linking the real
///   `/track/<slug>/<id>` product page.
///
/// If a store can't confirm the track (no match, or the request is blocked) it
/// is simply omitted, so the UI never shows a dead-end "search" link.
public enum PurchaseLinkService {
    public enum Store: String, CaseIterable, Sendable, Codable {
        case itunes
        case beatport

        public var displayName: String {
            switch self {
            case .itunes:
                return "iTunes"
            case .beatport:
                return "Beatport"
            }
        }
    }

    public struct PurchaseLink: Identifiable, Sendable, Hashable, Codable {
        public let id: UUID
        public let store: Store
        public let title: String
        public let subtitle: String?
        /// The specific version/mix of the track (e.g. "Extended", "Radio
        /// Edit", "Dirty", "Intro"). Used to let the user pick between multiple
        /// versions the same store carries. "Original" when unspecified.
        public let versionLabel: String
        public let priceText: String?
        public let url: URL

        public init(
            id: UUID = UUID(),
            store: Store,
            title: String,
            subtitle: String? = nil,
            versionLabel: String = "Original",
            priceText: String? = nil,
            url: URL
        ) {
            self.id = id
            self.store = store
            self.title = title
            self.subtitle = subtitle
            self.versionLabel = versionLabel.isEmpty ? "Original" : versionLabel
            self.priceText = priceText
            self.url = url
        }
    }

    /// A resolved Beatport search hit (before match filtering / URL building).
    struct BeatportTrack: Sendable, Equatable {
        let trackID: Int
        let trackName: String
        let mixName: String
        let artists: [String]
        let priceDisplay: String?
    }

    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// Builds the "artist title" query used across every store.
    public static func searchQuery(title: String, artist: String) -> String {
        [artist, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Resolves confirmed purchase links for a track. Stores that can't confirm
    /// the track are omitted. Network failures degrade to an empty list rather
    /// than throwing so the caller always gets a usable (possibly empty) set.
    public static func purchaseLinks(
        title: String,
        artist: String,
        maxPerStore: Int = 8,
        session: URLSession = .shared
    ) async -> [PurchaseLink] {
        guard !searchQuery(title: title, artist: artist).isEmpty else { return [] }

        async let itunes = resolvedITunesLinks(
            title: title, artist: artist, maxResults: maxPerStore, session: session
        )
        async let beatport = resolvedBeatportLinks(
            title: title, artist: artist, maxResults: maxPerStore, session: session
        )

        var links: [PurchaseLink] = []
        links.append(contentsOf: await itunes)
        links.append(contentsOf: await beatport)
        return links
    }

    private static func resolvedITunesLinks(
        title: String, artist: String, maxResults: Int, session: URLSession
    ) async -> [PurchaseLink] {
        (try? await itunesTrackLinks(title: title, artist: artist, maxResults: maxResults, session: session)) ?? []
    }

    private static func resolvedBeatportLinks(
        title: String, artist: String, maxResults: Int, session: URLSession
    ) async -> [PurchaseLink] {
        (try? await beatportTrackLinks(title: title, artist: artist, maxResults: maxResults, session: session)) ?? []
    }

    // MARK: - iTunes

    /// Resolves iTunes purchase links. The `term` song search is fast but its
    /// index misses some singles (e.g. recent DJ collabs), so when it finds no
    /// buyable result we fall back to enumerating the artist's catalog by
    /// artistId, which does list them.
    static func itunesTrackLinks(
        title: String,
        artist: String,
        maxResults: Int = 4,
        session: URLSession = .shared
    ) async throws -> [PurchaseLink] {
        let termLinks = try await itunesTermSongLinks(
            title: title, artist: artist, maxResults: maxResults, session: session
        )
        if !termLinks.isEmpty {
            return termLinks
        }
        return try await itunesArtistCatalogLinks(
            title: title, artist: artist, maxResults: maxResults, session: session
        )
    }

    /// Fast path: the iTunes `term` song search on the core title.
    private static func itunesTermSongLinks(
        title: String,
        artist: String,
        maxResults: Int,
        session: URLSession
    ) async throws -> [PurchaseLink] {
        // Search on the core title (version stripped) so the API returns every
        // version of the song — original, Radio Edit, Extended, remixes, etc.
        let term = searchQuery(title: coreTitle(title), artist: artist)
        guard !term.isEmpty else { return [] }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: term),
            URLQueryItem(name: "country", value: "US"),
            URLQueryItem(name: "entity", value: "song"),
            URLQueryItem(name: "media", value: "music"),
            URLQueryItem(name: "limit", value: "50")
        ]

        guard let url = components?.url else { return [] }

        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(ITunesPurchaseResponse.self, from: data)
        return buildITunesLinks(from: decoded.results, title: title, artist: artist, maxResults: maxResults)
    }

    /// Fallback path: look up each credited artist's iTunes id and scan their
    /// song catalog for the track. Only runs when the term search came up empty.
    private static func itunesArtistCatalogLinks(
        title: String,
        artist: String,
        maxResults: Int,
        session: URLSession
    ) async throws -> [PurchaseLink] {
        for name in artistNameList(artist).prefix(2) {
            guard let artistId = try await itunesArtistID(for: name, session: session) else { continue }

            var components = URLComponents(string: "https://itunes.apple.com/lookup")
            components?.queryItems = [
                URLQueryItem(name: "id", value: String(artistId)),
                URLQueryItem(name: "country", value: "US"),
                URLQueryItem(name: "entity", value: "song"),
                URLQueryItem(name: "limit", value: "200")
            ]
            guard let url = components?.url else { continue }

            let (data, _) = try await session.data(from: url)
            let decoded = try JSONDecoder().decode(ITunesPurchaseResponse.self, from: data)
            let links = buildITunesLinks(from: decoded.results, title: title, artist: artist, maxResults: maxResults)
            if !links.isEmpty {
                return links
            }
        }
        return []
    }

    private static func itunesArtistID(for name: String, session: URLSession) async throws -> Int? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var components = URLComponents(string: "https://itunes.apple.com/search")
        components?.queryItems = [
            URLQueryItem(name: "term", value: trimmed),
            URLQueryItem(name: "country", value: "US"),
            URLQueryItem(name: "entity", value: "musicArtist"),
            URLQueryItem(name: "limit", value: "5")
        ]
        guard let url = components?.url else { return nil }

        let (data, _) = try await session.data(from: url)
        let decoded = try JSONDecoder().decode(ITunesArtistResponse.self, from: data)

        let target = normalizedKey(trimmed)
        if let exact = decoded.results.first(where: { normalizedKey($0.artistName ?? "") == target }) {
            return exact.artistId
        }
        return decoded.results.first?.artistId
    }

    /// Shared builder: filters iTunes results to purchasable, matching versions
    /// and turns them into product links. Only tracks with a positive
    /// `trackPrice` are kept — streaming-only results have no price and open to
    /// a "not available for purchase" page when forced to the iTunes Store.
    private static func buildITunesLinks(
        from tracks: [ITunesPurchaseTrack],
        title: String,
        artist: String,
        maxResults: Int
    ) -> [PurchaseLink] {
        var links: [PurchaseLink] = []
        var seenVersions = Set<String>()
        for track in tracks {
            guard
                let urlString = track.trackViewUrl,
                let productURL = iTunesStoreURL(from: urlString),
                let trackName = track.trackName,
                let trackPrice = track.trackPrice,
                trackPrice > 0,
                titleMatchesAnyVersion(title, trackName),
                artistMatches(entryArtist: artist, candidate: track.artistName ?? "")
            else {
                continue
            }

            let version = versionLabel(fromTrackName: trackName)
            guard seenVersions.insert(version.lowercased()).inserted else { continue }

            let name = [track.artistName, track.trackName]
                .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .joined(separator: " - ")

            let price = itunesPriceText(price: trackPrice, currency: track.currency)

            links.append(
                PurchaseLink(
                    store: .itunes,
                    title: name.isEmpty ? "Buy on iTunes" : name,
                    subtitle: price,
                    versionLabel: version,
                    priceText: price,
                    url: productURL
                )
            )

            if links.count >= max(1, maxResults) { break }
        }

        return links
    }

    private static func itunesPriceText(price: Double?, currency: String?) -> String? {
        guard let price, price > 0 else { return nil }
        let amount = String(format: "%.2f", price)
        if let currency, !currency.isEmpty {
            return "\(amount) \(currency)"
        }
        return amount
    }

    /// The Search API returns `music.apple.com` links that open Apple Music
    /// (streaming). Appending `app=itunes` routes to the iTunes Store buy view
    /// instead. Existing query items (`i`, `uo`) are preserved.
    static func iTunesStoreURL(from raw: String) -> URL? {
        guard var components = URLComponents(string: raw) else {
            return URL(string: raw)
        }
        var items = components.queryItems ?? []
        if !items.contains(where: { $0.name == "app" }) {
            items.append(URLQueryItem(name: "app", value: "itunes"))
        }
        components.queryItems = items
        return components.url ?? URL(string: raw)
    }

    // MARK: - Beatport

    static func beatportTrackLinks(
        title: String,
        artist: String,
        maxResults: Int = 4,
        session: URLSession = .shared
    ) async throws -> [PurchaseLink] {
        let query = searchQuery(title: coreTitle(title), artist: artist)
        guard !query.isEmpty else { return [] }

        var components = URLComponents(string: "https://www.beatport.com/search")
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { return [] }

        var request = URLRequest(url: url)
        request.setValue(browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let html = String(data: data, encoding: .utf8)
        else {
            return []
        }

        let tracks = parseBeatportTracks(fromHTML: html)
        return beatportLinks(matchingTitle: title, artist: artist, in: tracks, maxResults: maxResults)
    }

    /// Extracts the Beatport search results from the `__NEXT_DATA__` JSON blob.
    /// Kept internal + pure so it can be unit-tested without network access.
    static func parseBeatportTracks(fromHTML html: String) -> [BeatportTrack] {
        guard
            let jsonString = nextDataJSON(fromHTML: html),
            let jsonData = jsonString.data(using: .utf8),
            let root = try? JSONSerialization.jsonObject(with: jsonData),
            let rawTracks = firstTracksData(in: root)
        else {
            return []
        }

        return rawTracks.compactMap { raw in
            guard
                let dict = raw as? [String: Any],
                let trackID = intValue(dict["track_id"]),
                let trackName = (dict["track_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !trackName.isEmpty
            else {
                return nil
            }

            let mixName = (dict["mix_name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""

            let artists: [String] = (dict["artists"] as? [Any])?.compactMap {
                ($0 as? [String: Any])?["artist_name"] as? String
            } ?? []

            let priceDisplay = (dict["price"] as? [String: Any])?["display"] as? String

            return BeatportTrack(
                trackID: trackID,
                trackName: trackName,
                mixName: mixName,
                artists: artists,
                priceDisplay: priceDisplay
            )
        }
    }

    /// Filters resolved Beatport tracks down to confirmed matches and builds the
    /// real product-page links (`/track/<slug>/<id>`; Beatport resolves by the
    /// numeric id regardless of the slug).
    static func beatportLinks(
        matchingTitle title: String,
        artist: String,
        in tracks: [BeatportTrack],
        maxResults: Int = 4
    ) -> [PurchaseLink] {
        var links: [PurchaseLink] = []
        var seenIDs = Set<Int>()
        var seenVersions = Set<String>()

        for track in tracks {
            guard
                titleMatchesAnyVersion(title, track.trackName),
                artistMatches(entryArtist: artist, candidate: track.artists.joined(separator: " "))
            else {
                continue
            }
            guard seenIDs.insert(track.trackID).inserted else { continue }
            guard let url = beatportTrackURL(name: track.trackName, id: track.trackID) else { continue }

            let version = track.mixName.isEmpty ? "Original" : track.mixName
            guard seenVersions.insert(version.lowercased()).inserted else { continue }

            let displayName = track.mixName.isEmpty
                ? track.trackName
                : "\(track.trackName) (\(track.mixName))"
            let subtitle = [track.artists.joined(separator: ", "), track.priceDisplay]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")

            links.append(
                PurchaseLink(
                    store: .beatport,
                    title: displayName,
                    subtitle: subtitle.isEmpty ? nil : subtitle,
                    versionLabel: version,
                    priceText: track.priceDisplay,
                    url: url
                )
            )

            if links.count >= max(1, maxResults) { break }
        }

        return links
    }

    private static func beatportTrackURL(name: String, id: Int) -> URL? {
        let slug = slugify(name)
        let path = slug.isEmpty ? "track" : "track/\(slug)"
        return URL(string: "https://www.beatport.com/\(path)/\(id)")
    }

    private static func nextDataJSON(fromHTML html: String) -> String? {
        let marker = "<script id=\"__NEXT_DATA__\" type=\"application/json\">"
        guard let start = html.range(of: marker) else { return nil }
        let afterStart = html[start.upperBound...]
        guard let end = afterStart.range(of: "</script>") else { return nil }
        return String(afterStart[..<end.lowerBound])
    }

    /// Recursively finds the first `tracks.data` array in the decoded JSON. The
    /// exact query index inside `dehydratedState` is not stable, so we search
    /// for the shape instead of hard-coding a path.
    private static func firstTracksData(in object: Any) -> [Any]? {
        if let dict = object as? [String: Any] {
            if let tracks = dict["tracks"] as? [String: Any], let data = tracks["data"] as? [Any] {
                return data
            }
            for value in dict.values {
                if let found = firstTracksData(in: value) {
                    return found
                }
            }
        } else if let array = object as? [Any] {
            for value in array {
                if let found = firstTracksData(in: value) {
                    return found
                }
            }
        }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let intValue = value as? Int { return intValue }
        if let doubleValue = value as? Double { return Int(doubleValue) }
        if let stringValue = value as? String { return Int(stringValue) }
        return nil
    }

    // MARK: - Matching helpers

    static func slugify(_ value: String) -> String {
        let folded = value.folding(options: .diacriticInsensitive, locale: .current).lowercased()
        var slug = ""
        var lastWasHyphen = false
        for scalar in folded.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                slug.unicodeScalars.append(scalar)
                lastWasHyphen = false
            } else if !lastWasHyphen {
                slug.append("-")
                lastWasHyphen = true
            }
        }
        return slug.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
    }

    private static func normalizedKey(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        var result = ""
        var lastWasSpace = false
        for scalar in folded.unicodeScalars {
            if (scalar >= "a" && scalar <= "z") || (scalar >= "0" && scalar <= "9") {
                result.unicodeScalars.append(scalar)
                lastWasSpace = false
            } else if !lastWasSpace {
                result.append(" ")
                lastWasSpace = true
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    static func titleMatches(_ entryTitle: String, _ candidateTitle: String) -> Bool {
        let a = normalizedKey(entryTitle)
        let b = normalizedKey(candidateTitle)
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b || a.contains(b) || b.contains(a)
    }

    /// Like `titleMatches` but compares the *core* titles (version/mix
    /// descriptors stripped), so every version of a song matches even when the
    /// playlist entry pins a specific one (e.g. "Feel So Close - Radio Edit"
    /// still matches the Original and Extended versions).
    static func titleMatchesAnyVersion(_ entryTitle: String, _ candidateTitle: String) -> Bool {
        titleMatches(coreTitle(entryTitle), coreTitle(candidateTitle))
    }

    /// Strips trailing version descriptors from a title: parenthetical/bracket
    /// suffixes like "(Radio Edit)"/"[Extended Mix]" and a dash-separated
    /// trailing descriptor like " - Radio Edit".
    static func coreTitle(_ name: String) -> String {
        var value = name.trimmingCharacters(in: .whitespaces)

        while let last = value.last, last == ")" || last == "]" {
            let opener: Character = last == ")" ? "(" : "["
            guard let openIndex = value.lastIndex(of: opener) else { break }
            value = String(value[..<openIndex]).trimmingCharacters(in: .whitespaces)
        }

        if let dashRange = value.range(of: " - ", options: .backwards) {
            value = String(value[..<dashRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        }

        let trimmed = value.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? name.trimmingCharacters(in: .whitespaces) : trimmed
    }

    static func artistMatches(entryArtist: String, candidate: String) -> Bool {
        let entryWords = artistWordSet(entryArtist)
        // An empty entry artist means "don't constrain by artist".
        guard !entryWords.isEmpty else { return true }
        let candidateWords = artistWordSet(candidate)
        guard !candidateWords.isEmpty else { return false }
        // Order-independent: match when one credit's artist words are all
        // present in the other. Handles reordered multi-artist credits
        // ("Disco Lines & Tinashe" vs "Tinashe, Disco Lines") and remixes that
        // add an extra artist ("Tinashe, AVELLO, Disco Lines").
        return entryWords.isSubset(of: candidateWords) || candidateWords.isSubset(of: entryWords)
    }

    /// Splits an artist credit into a set of normalized name words, dropping
    /// separators (`&`, `,`, `x`, `feat`, …) which normalization turns into
    /// spaces.
    private static func artistWordSet(_ raw: String) -> Set<String> {
        Set(normalizedKey(raw).split(separator: " ").map(String.init))
    }

    /// Splits a multi-artist credit into individual artist names, e.g.
    /// "Disco Lines & Tinashe" -> ["Disco Lines", "Tinashe"].
    static func artistNameList(_ raw: String) -> [String] {
        var working = " \(raw) "
        let separators = [
            " & ", " and ", " x ", " X ", ", ", " feat. ", " feat ", " ft. ",
            " ft ", " featuring ", " vs. ", " vs ", " with ", " + ", " / "
        ]
        for separator in separators {
            working = working.replacingOccurrences(of: separator, with: "|")
        }
        var seen = Set<String>()
        var names: [String] = []
        for part in working.split(separator: "|") {
            let name = part.trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty, seen.insert(name.lowercased()).inserted else { continue }
            names.append(name)
        }
        return names
    }

    /// Extracts a version/mix label from an iTunes track name, e.g.
    /// "Losing It (Radio Edit)" -> "Radio Edit". Returns "Original" when the
    /// name carries no trailing parenthetical/bracketed descriptor.
    static func versionLabel(fromTrackName name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        let closers: [(open: Character, close: Character)] = [("(", ")"), ("[", "]")]
        for pair in closers where trimmed.hasSuffix(String(pair.close)) {
            guard let openIndex = trimmed.lastIndex(of: pair.open) else { continue }
            let inner = trimmed[trimmed.index(after: openIndex)..<trimmed.index(before: trimmed.endIndex)]
            let label = inner.trimmingCharacters(in: .whitespaces)
            if !label.isEmpty {
                return label
            }
        }
        return "Original"
    }
}

private struct ITunesPurchaseResponse: Decodable {
    let results: [ITunesPurchaseTrack]
}

private struct ITunesPurchaseTrack: Decodable {
    let trackName: String?
    let artistName: String?
    let trackViewUrl: String?
    let trackPrice: Double?
    let currency: String?
}

private struct ITunesArtistResponse: Decodable {
    let results: [ITunesArtist]
}

private struct ITunesArtist: Decodable {
    let artistId: Int?
    let artistName: String?
}
