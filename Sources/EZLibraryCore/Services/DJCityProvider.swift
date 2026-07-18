import Foundation

/// Searches DJcity with the user's own subscription credentials.
///
/// DJcity uses a traditional form login that establishes a session cookie, then
/// serves HTML search results. We log in, then GET the store search page and
/// parse the track rows. Endpoints/selectors are centralized and the HTML
/// parser is pure + unit-tested so it can be adjusted once verified against a
/// live account.
///
/// NOTE: The login endpoint / form field names and the search URL below are
/// best-effort and must be confirmed with a real signed-in session (browser
/// DevTools → Network). The pure `parseResults(fromHTML:)` is the stable part.
public struct DJCityProvider: RecordPoolProvider {
    public let pool: RecordPool = .djCity

    private enum Endpoint {
        static let base = "https://www.djcity.com"
        static let login = base + "/login"
        static let search = base + "/us/store/"
    }

    private static let browserUserAgent =
        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.4 Safari/605.1.15"

    /// Shared session with persistent cookie storage so the login session
    /// carries across searches (and track rows) without re-authenticating.
    private static let sharedSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.httpCookieStorage = HTTPCookieStorage.shared
        configuration.httpAdditionalHeaders = ["User-Agent": browserUserAgent]
        return URLSession(configuration: configuration)
    }()

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

        let authedSession = Self.sharedSession

        // Only sign in when we don't have a recent login window for this pool.
        if await !RecordPoolSessionCache.shared.isLoginValid(for: pool) {
            try await login(credentials: credentials, session: authedSession)
            await RecordPoolSessionCache.shared.markLoggedIn(for: pool)
        }

        let html = try await runSearch(query: query, session: authedSession)

        let parsed = Self.parseResults(fromHTML: html, baseURL: Endpoint.base)
        return RecordPoolMatch.confirmed(parsed, title: title, artist: artist, limit: maxResults)
    }

    // MARK: - Network

    private func login(credentials: RecordPoolCredentials, session: URLSession) async throws {
        guard let url = URL(string: Endpoint.login) else { throw RecordPoolError.notConfigured }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        var body = URLComponents()
        body.queryItems = [
            URLQueryItem(name: "email", value: credentials.username),
            URLQueryItem(name: "password", value: credentials.password),
        ]
        request.httpBody = body.percentEncodedQuery?.data(using: .utf8)

        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<400).contains(http.statusCode) else {
            throw RecordPoolError.loginFailed
        }
    }

    private func runSearch(query: String, session: URLSession) async throws -> String {
        var components = URLComponents(string: Endpoint.search)
        components?.queryItems = [URLQueryItem(name: "q", value: query)]
        guard let url = components?.url else { throw RecordPoolError.searchFailed }

        var request = URLRequest(url: url)
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)
        guard
            let http = response as? HTTPURLResponse,
            (200..<300).contains(http.statusCode),
            let html = String(data: data, encoding: .utf8)
        else {
            throw RecordPoolError.searchFailed
        }
        return html
    }

    // MARK: - Parsing (pure, unit-tested)

    /// Extracts track results from DJcity's search HTML. Looks for anchors that
    /// point at a track/song page and reads the visible title text, resolving
    /// relative hrefs against `baseURL`. Artist is left blank when the markup
    /// doesn't separate it (confirmation then relies on the title).
    static func parseResults(fromHTML html: String, baseURL: String) -> [RecordPoolResult] {
        var results: [RecordPoolResult] = []
        var seen = Set<String>()

        // Match anchors linking to a song/track detail page.
        let pattern = #"<a[^>]+href=\"([^\"]*/(?:song|track|store/song)[^\"]*)\"[^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else {
            return []
        }

        let range = NSRange(html.startIndex..., in: html)
        for match in regex.matches(in: html, options: [], range: range) {
            guard
                match.numberOfRanges >= 3,
                let hrefRange = Range(match.range(at: 1), in: html),
                let innerRange = Range(match.range(at: 2), in: html)
            else {
                continue
            }

            let href = String(html[hrefRange])
            let title = strippingTags(String(html[innerRange])).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { continue }

            let absolute = href.hasPrefix("http") ? href : baseURL + (href.hasPrefix("/") ? href : "/" + href)
            guard let url = URL(string: absolute), seen.insert(absolute).inserted else { continue }

            results.append(
                RecordPoolResult(pool: .djCity, title: title, artist: "", versionLabel: nil, url: url)
            )
        }

        return results
    }

    private static func strippingTags(_ html: String) -> String {
        let withoutTags = html.replacingOccurrences(
            of: "<[^>]+>",
            with: " ",
            options: .regularExpression
        )
        return withoutTags
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .split(separator: " ")
            .joined(separator: " ")
    }
}
