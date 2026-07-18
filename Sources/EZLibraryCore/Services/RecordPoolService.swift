import Foundation

/// One confirmed hit for a track inside a record pool the user subscribes to.
/// Links straight to the track's page in that pool (where the user is signed
/// in through their browser).
public struct RecordPoolResult: Identifiable, Sendable, Hashable {
    public let id: UUID
    public let pool: RecordPool
    public let title: String
    public let artist: String
    /// The specific version/mix (e.g. "Clean", "Dirty", "Intro", "Extended")
    /// when the pool exposes it. `nil` when unspecified.
    public let versionLabel: String?
    public let url: URL

    public init(
        id: UUID = UUID(),
        pool: RecordPool,
        title: String,
        artist: String,
        versionLabel: String? = nil,
        url: URL
    ) {
        self.id = id
        self.pool = pool
        self.title = title
        self.artist = artist
        self.versionLabel = versionLabel
        self.url = url
    }
}

/// Authenticates against a record pool with the user's own credentials and
/// searches it for a track. Providers confirm the track before returning a
/// result — a failed login or blocked request degrades to an empty list so the
/// UI never shows a dead-end link.
public protocol RecordPoolProvider: Sendable {
    var pool: RecordPool { get }

    func search(
        title: String,
        artist: String,
        credentials: RecordPoolCredentials,
        maxResults: Int,
        session: URLSession
    ) async throws -> [RecordPoolResult]
}

public enum RecordPoolError: Error, LocalizedError {
    case loginFailed
    case searchFailed
    case unauthorized
    case notConfigured

    public var errorDescription: String? {
        switch self {
        case .loginFailed:
            return "Couldn't sign in to the record pool with the saved credentials."
        case .searchFailed:
            return "The record pool search request failed."
        case .unauthorized:
            return "The record pool session expired."
        case .notConfigured:
            return "This record pool isn't configured yet."
        }
    }
}

/// Coordinates credentialed search across every record pool the user has signed
/// into. Runs the configured pools concurrently and merges their confirmed
/// hits; a pool that fails (bad login, network, layout change) is simply
/// omitted rather than throwing.
public enum RecordPoolService {
    /// Registered providers, one per supported pool.
    static let providers: [RecordPool: any RecordPoolProvider] = [
        .bpmSupreme: BPMSupremeProvider(),
        .djCity: DJCityProvider(),
    ]

    /// Pools that currently have stored credentials (i.e. the user has signed
    /// in). Only these are searched.
    public static func configuredPools(credentialStore: RecordPoolCredentialStore) -> [RecordPool] {
        RecordPool.allCases.filter { credentialStore.hasCredentials(for: $0) }
    }

    /// Whether the user has signed into at least one pool (used to decide
    /// whether to auto-search at all).
    public static func hasAnyConfiguredPool(credentialStore: RecordPoolCredentialStore) -> Bool {
        !configuredPools(credentialStore: credentialStore).isEmpty
    }

    public static func search(
        title: String,
        artist: String,
        credentialStore: RecordPoolCredentialStore = RecordPoolCredentialStore(),
        maxPerPool: Int = 6,
        session: URLSession = .shared
    ) async -> [RecordPoolResult] {
        let pools = configuredPools(credentialStore: credentialStore)
        guard !pools.isEmpty else { return [] }

        return await withTaskGroup(of: [RecordPoolResult].self) { group in
            for pool in pools {
                guard
                    let provider = providers[pool],
                    let credentials = try? credentialStore.credentials(for: pool)
                else {
                    continue
                }

                group.addTask {
                    (try? await provider.search(
                        title: title,
                        artist: artist,
                        credentials: credentials,
                        maxResults: maxPerPool,
                        session: session
                    )) ?? []
                }
            }

            var merged: [RecordPoolResult] = []
            for await results in group {
                merged.append(contentsOf: results)
            }
            return merged
        }
    }
}
