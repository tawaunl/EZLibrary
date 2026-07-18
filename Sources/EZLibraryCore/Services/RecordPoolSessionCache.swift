import Foundation

/// Process-lifetime cache that avoids re-authenticating a record pool for every
/// track row. Bearer tokens (BPM Supreme) and "recently logged in" windows
/// (cookie-based pools like DJcity) are memoized with a short TTL. Only
/// `Sendable` values (String/Date) cross the actor boundary — cookies live in
/// each provider's shared `URLSession` cookie storage.
actor RecordPoolSessionCache {
    static let shared = RecordPoolSessionCache()

    private var bearerTokens: [RecordPool: (token: String, expires: Date)] = [:]
    private var loginExpiry: [RecordPool: Date] = [:]

    // MARK: - Bearer tokens (BPM Supreme)

    func bearerToken(for pool: RecordPool) -> String? {
        guard let entry = bearerTokens[pool], entry.expires > Date() else { return nil }
        return entry.token
    }

    func setBearerToken(_ token: String, for pool: RecordPool, ttl: TimeInterval = 600) {
        bearerTokens[pool] = (token, Date().addingTimeInterval(ttl))
    }

    func clearBearerToken(for pool: RecordPool) {
        bearerTokens[pool] = nil
    }

    // MARK: - Cookie session windows (DJcity)

    func isLoginValid(for pool: RecordPool) -> Bool {
        guard let expiry = loginExpiry[pool] else { return false }
        return expiry > Date()
    }

    func markLoggedIn(for pool: RecordPool, ttl: TimeInterval = 1800) {
        loginExpiry[pool] = Date().addingTimeInterval(ttl)
    }

    func invalidateLogin(for pool: RecordPool) {
        loginExpiry[pool] = nil
    }
}
