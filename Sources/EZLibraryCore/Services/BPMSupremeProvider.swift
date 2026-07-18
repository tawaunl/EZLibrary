import Foundation

/// Searches BPM Supreme with the user's own subscription credentials.
///
/// BPM Supreme's web app (app.bpmsupreme.com) is a single-page app backed by a
/// private JSON API. The exact endpoints are centralized in `Endpoint` and the
/// response mapping is isolated in the pure `parse…` helpers so they can be
/// unit-tested with fixtures and adjusted once verified against a live account.
///
/// NOTE: The endpoint paths / field names below are best-effort and must be
/// confirmed with a real signed-in session (browser DevTools → Network). The
/// pure parsers are tolerant of shape differences (recursive key lookup), so
/// only the URLs/auth header should ever need tweaking.
public struct BPMSupremeProvider: RecordPoolProvider {
    public let pool: RecordPool = .bpmSupreme

    private enum Endpoint {
        static let apiBase = "https://api.bpmsupreme.com"
        static let login = apiBase + "/v1/account/sign_in"
        static let search = apiBase + "/v1/albums"
        static let trackWebBase = "https://app.bpmsupreme.com/d/song/"
    }

    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    public init() {}

    public func search(
        title: String,
        artist: String,
        credentials: RecordPoolCredentials,
        maxResults: Int,
        session: URLSession
    ) async throws -> [RecordPoolResult] {
        let query = RecordPoolMatch.query(title: title, artist: artist)
        guard !query.isEmpty else { return [] }

        // Reuse a cached bearer token across track rows; only sign in when it's
        // missing or expired. On a 401 (stale token) drop it and retry once.
        var token = try await cachedOrFreshToken(credentials: credentials, session: session)
        do {
            let data = try await runSearch(query: query, token: token, maxResults: maxResults, session: session)
            let parsed = Self.parseResults(fromSearchJSON: data)
            return RecordPoolMatch.confirmed(parsed, title: title, artist: artist, limit: maxResults)
        } catch RecordPoolError.unauthorized {
            await RecordPoolSessionCache.shared.clearBearerToken(for: pool)
            token = try await login(credentials: credentials, session: session)
            await RecordPoolSessionCache.shared.setBearerToken(token, for: pool)
            let data = try await runSearch(query: query, token: token, maxResults: maxResults, session: session)
            let parsed = Self.parseResults(fromSearchJSON: data)
            return RecordPoolMatch.confirmed(parsed, title: title, artist: artist, limit: maxResults)
        }
    }

    private func cachedOrFreshToken(credentials: RecordPoolCredentials, session: URLSession) async throws -> String {
        if let cached = await RecordPoolSessionCache.shared.bearerToken(for: pool) {
            return cached
        }
        let token = try await login(credentials: credentials, session: session)
        await RecordPoolSessionCache.shared.setBearerToken(token, for: pool)
        return token
    }

    // MARK: - Network

    private func login(credentials: RecordPoolCredentials, session: URLSession) async throws -> String {
        guard let url = URL(string: Endpoint.login) else { throw RecordPoolError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15
        request.httpBody = try JSONSerialization.data(withJSONObject: [
            "email": credentials.username,
            "password": credentials.password,
        ])

        let (data, response) = try await session.data(for: request)
        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let token = Self.parseToken(fromLoginJSON: data)
        else {
            throw RecordPoolError.loginFailed
        }
        return token
    }

    private func runSearch(
        query: String,
        token: String,
        maxResults: Int,
        session: URLSession
    ) async throws -> Data {
        var components = URLComponents(string: Endpoint.search)
        components?.queryItems = [
            URLQueryItem(name: "search", value: query),
            URLQueryItem(name: "limit", value: String(max(1, min(maxResults, 25)))),
        ]
        guard let url = components?.url else { throw RecordPoolError.searchFailed }

        var request = URLRequest(url: url)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue(Self.browserUserAgent, forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RecordPoolError.searchFailed
        }
        if http.statusCode == 401 || http.statusCode == 403 {
            throw RecordPoolError.unauthorized
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RecordPoolError.searchFailed
        }
        return data
    }

    // MARK: - Parsing (pure, unit-tested)

    /// Extracts an auth token from the login response. Tolerant of nesting:
    /// searches for the first `token`/`access_token` string anywhere in the
    /// JSON object graph.
    static func parseToken(fromLoginJSON data: Data) -> String? {
        guard let root = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return firstString(forKeys: ["access_token", "token", "auth_token", "jwt"], in: root)
    }

    /// Maps the search response JSON into results. Looks for the first array of
    /// track-like objects and reads title/artist/version/url from each,
    /// tolerating a few common field names.
    static func parseResults(fromSearchJSON data: Data) -> [RecordPoolResult] {
        guard
            let root = try? JSONSerialization.jsonObject(with: data),
            let items = firstObjectArray(in: root)
        else {
            return []
        }

        return items.compactMap { object -> RecordPoolResult? in
            guard let title = string(forKeys: ["title", "name", "song_name"], in: object), !title.isEmpty else {
                return nil
            }

            let artist = artistName(in: object)
            let version = string(forKeys: ["version", "mix_name", "type"], in: object)
            guard let url = trackURL(in: object) else { return nil }

            return RecordPoolResult(
                pool: .bpmSupreme,
                title: title,
                artist: artist,
                versionLabel: (version?.isEmpty == false) ? version : nil,
                url: url
            )
        }
    }

    private static func trackURL(in object: [String: Any]) -> URL? {
        if let explicit = string(forKeys: ["url", "web_url", "share_url"], in: object),
           let url = URL(string: explicit) {
            return url
        }
        if let slug = string(forKeys: ["slug", "permalink"], in: object) {
            return URL(string: Endpoint.trackWebBase + slug)
        }
        if let id = idString(in: object) {
            return URL(string: Endpoint.trackWebBase + id)
        }
        return nil
    }

    private static func artistName(in object: [String: Any]) -> String {
        if let direct = string(forKeys: ["artist", "artist_name", "artists_title"], in: object), !direct.isEmpty {
            return direct
        }
        if let artists = object["artists"] as? [[String: Any]] {
            let names = artists.compactMap { string(forKeys: ["name", "artist_name"], in: $0) }
            if !names.isEmpty { return names.joined(separator: ", ") }
        }
        return ""
    }

    private static func idString(in object: [String: Any]) -> String? {
        if let intID = object["id"] as? Int { return String(intID) }
        if let strID = object["id"] as? String { return strID }
        return nil
    }

    // MARK: - Tolerant JSON helpers

    private static func string(forKeys keys: [String], in object: [String: Any]) -> String? {
        for key in keys {
            if let value = object[key] as? String { return value.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return nil
    }

    private static func firstString(forKeys keys: [String], in json: Any) -> String? {
        if let object = json as? [String: Any] {
            for key in keys {
                if let value = object[key] as? String, !value.isEmpty { return value }
            }
            for value in object.values {
                if let found = firstString(forKeys: keys, in: value) { return found }
            }
        } else if let array = json as? [Any] {
            for value in array {
                if let found = firstString(forKeys: keys, in: value) { return found }
            }
        }
        return nil
    }

    /// Finds the first array of dictionaries that looks like track results.
    private static func firstObjectArray(in json: Any) -> [[String: Any]]? {
        if let array = json as? [[String: Any]], looksLikeTracks(array) {
            return array
        }
        if let object = json as? [String: Any] {
            // Prefer a "data"/"results" array when present.
            for key in ["data", "results", "albums", "tracks", "songs"] {
                if let array = object[key] as? [[String: Any]], looksLikeTracks(array) {
                    return array
                }
            }
            for value in object.values {
                if let found = firstObjectArray(in: value) { return found }
            }
        } else if let array = json as? [Any] {
            for value in array {
                if let found = firstObjectArray(in: value) { return found }
            }
        }
        return nil
    }

    private static func looksLikeTracks(_ array: [[String: Any]]) -> Bool {
        guard let first = array.first else { return false }
        return first["title"] != nil || first["name"] != nil || first["song_name"] != nil
    }
}
