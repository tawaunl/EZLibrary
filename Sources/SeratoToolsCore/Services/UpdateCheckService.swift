import Foundation

/// Information about a published EZLibrary release on GitHub.
public struct AppReleaseInfo: Sendable, Equatable {
    /// The version parsed from the release tag (leading `v` stripped), e.g. `0.1.0.3`.
    public let version: String
    /// The raw tag name, e.g. `v0.1.0.3`.
    public let tagName: String
    /// The human-facing release page.
    public let releasePageURL: URL
    /// Direct download URL for the `.pkg` installer asset, when present.
    public let installerDownloadURL: URL?
    /// The release notes / body text.
    public let releaseNotes: String
    /// When the release was published.
    public let publishedAt: Date?

    public init(
        version: String,
        tagName: String,
        releasePageURL: URL,
        installerDownloadURL: URL?,
        releaseNotes: String,
        publishedAt: Date?
    ) {
        self.version = version
        self.tagName = tagName
        self.releasePageURL = releasePageURL
        self.installerDownloadURL = installerDownloadURL
        self.releaseNotes = releaseNotes
        self.publishedAt = publishedAt
    }
}

/// The outcome of an update check.
public enum UpdateCheckResult: Sendable, Equatable {
    /// The running app is the newest published release.
    case upToDate(currentVersion: String, latest: AppReleaseInfo)
    /// A newer release is available.
    case updateAvailable(currentVersion: String, latest: AppReleaseInfo)
}

public enum UpdateCheckError: LocalizedError {
    case invalidResponse
    case notFound
    case rateLimited
    case server(statusCode: Int)
    case decoding
    case network(String)
    case unknownCurrentVersion

    public var errorDescription: String? {
        switch self {
        case .invalidResponse:
            return "EZLibrary received an unexpected response while checking for updates."
        case .notFound:
            return "No published releases were found for EZLibrary."
        case .rateLimited:
            return "GitHub temporarily rate-limited the update check."
        case .server(let statusCode):
            return "The update server returned an error (HTTP \(statusCode))."
        case .decoding:
            return "EZLibrary couldn't read the update information from GitHub."
        case .network(let message):
            return "Couldn't reach the update server: \(message)"
        case .unknownCurrentVersion:
            return "EZLibrary couldn't determine its own version to compare against."
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .rateLimited:
            return "Wait a few minutes and try checking for updates again."
        case .network:
            return "Check your internet connection and try again."
        default:
            return nil
        }
    }
}

/// Checks GitHub Releases for a newer version of EZLibrary.
public struct UpdateCheckService: Sendable {
    private let owner: String
    private let repository: String
    private let currentVersion: String?
    private let session: URLSession

    /// - Parameters:
    ///   - owner: GitHub repository owner.
    ///   - repository: GitHub repository name.
    ///   - currentVersion: The running app's version (short version + build, e.g. `0.1.0.3`).
    ///     Defaults to the value read from the main bundle's Info.plist.
    ///   - session: URLSession used for the request.
    public init(
        owner: String = "tawaunl",
        repository: String = "SeratoTools",
        currentVersion: String? = UpdateCheckService.bundleVersion(),
        session: URLSession = .shared
    ) {
        self.owner = owner
        self.repository = repository
        self.currentVersion = currentVersion
        self.session = session
    }

    /// Reads the running app version as `CFBundleShortVersionString.CFBundleVersion`
    /// (e.g. `0.1.0.3`) to match the release tag format produced by Scripts/release.sh.
    public static func bundleVersion() -> String? {
        let info = Bundle.main.infoDictionary
        guard let short = info?["CFBundleShortVersionString"] as? String, !short.isEmpty else {
            return nil
        }
        if let build = info?["CFBundleVersion"] as? String, !build.isEmpty {
            return "\(short).\(build)"
        }
        return short
    }

    /// Fetches the latest release and compares it against the running version.
    public func checkForUpdates() async throws -> UpdateCheckResult {
        guard let currentVersion else {
            throw UpdateCheckError.unknownCurrentVersion
        }

        let latest = try await fetchLatestRelease()
        if Self.isVersion(latest.version, newerThan: currentVersion) {
            return .updateAvailable(currentVersion: currentVersion, latest: latest)
        }
        return .upToDate(currentVersion: currentVersion, latest: latest)
    }

    /// Fetches metadata for the newest published (non-draft, non-prerelease) release.
    public func fetchLatestRelease() async throws -> AppReleaseInfo {
        let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/releases/latest")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("EZLibrary", forHTTPHeaderField: "User-Agent")
        request.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        request.timeoutInterval = 20

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw UpdateCheckError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UpdateCheckError.invalidResponse
        }

        switch http.statusCode {
        case 200:
            break
        case 404:
            throw UpdateCheckError.notFound
        case 403, 429:
            throw UpdateCheckError.rateLimited
        default:
            throw UpdateCheckError.server(statusCode: http.statusCode)
        }

        let payload: GitHubRelease
        do {
            payload = try JSONDecoder().decode(GitHubRelease.self, from: data)
        } catch {
            throw UpdateCheckError.decoding
        }

        let version = Self.normalizedVersion(from: payload.tagName)
        let installerAsset = payload.assets.first { $0.name.lowercased().hasSuffix(".pkg") }

        return AppReleaseInfo(
            version: version,
            tagName: payload.tagName,
            releasePageURL: URL(string: payload.htmlURL) ?? url,
            installerDownloadURL: installerAsset.flatMap { URL(string: $0.browserDownloadURL) },
            releaseNotes: payload.body ?? "",
            publishedAt: payload.publishedAt.flatMap(Self.iso8601Date(from:))
        )
    }

    // MARK: - Version comparison

    /// Strips a leading `v`/`V` and surrounding whitespace from a tag name.
    static func normalizedVersion(from tag: String) -> String {
        var value = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if let first = value.first, first == "v" || first == "V" {
            value.removeFirst()
        }
        return value
    }

    /// Compares two dotted numeric version strings (e.g. `0.1.0.3`).
    /// Missing trailing components are treated as `0`.
    public static func isVersion(_ lhs: String, newerThan rhs: String) -> Bool {
        let left = versionComponents(lhs)
        let right = versionComponents(rhs)
        let count = max(left.count, right.count)
        for index in 0..<count {
            let l = index < left.count ? left[index] : 0
            let r = index < right.count ? right[index] : 0
            if l != r {
                return l > r
            }
        }
        return false
    }

    private static func versionComponents(_ version: String) -> [Int] {
        normalizedVersion(from: version)
            .split(separator: ".")
            .map { component in
                let digits = component.prefix { $0.isNumber }
                return Int(digits) ?? 0
            }
    }

    private static func iso8601Date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        return formatter.date(from: string)
    }
}

// MARK: - GitHub API payloads

private struct GitHubRelease: Decodable {
    let tagName: String
    let htmlURL: String
    let body: String?
    let publishedAt: String?
    let assets: [Asset]

    struct Asset: Decodable {
        let name: String
        let browserDownloadURL: String

        enum CodingKeys: String, CodingKey {
            case name
            case browserDownloadURL = "browser_download_url"
        }
    }

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case htmlURL = "html_url"
        case body
        case publishedAt = "published_at"
        case assets
    }
}
