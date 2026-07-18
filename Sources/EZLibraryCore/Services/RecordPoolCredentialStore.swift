import Foundation
import Security

/// A DJ record pool the user pays for and can search from inside the app using
/// their own credentials. These are subscription services (not per-track
/// stores), so results are shown separately from the confirmed Buy links.
public enum RecordPool: String, CaseIterable, Sendable, Codable, Identifiable {
    case bpmSupreme
    case djCity

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bpmSupreme:
            return "BPM Supreme"
        case .djCity:
            return "DJcity"
        }
    }

    /// Where the user manages their subscription / signs in via the browser.
    public var homeURL: URL {
        switch self {
        case .bpmSupreme:
            return URL(string: "https://app.bpmsupreme.com")!
        case .djCity:
            return URL(string: "https://www.djcity.com")!
        }
    }
}

/// A username + password pair for a record pool. Never logged or persisted
/// anywhere except the macOS Keychain via `RecordPoolCredentialStore`.
public struct RecordPoolCredentials: Sendable, Hashable {
    public let username: String
    public let password: String

    public init(username: String, password: String) {
        self.username = username
        self.password = password
    }
}

/// Securely stores record-pool credentials in the macOS Keychain (generic
/// password items). Credentials are never written to `UserDefaults`/plists and
/// never logged. Each pool gets its own Keychain service entry so it can be
/// added or removed independently.
public struct RecordPoolCredentialStore: Sendable {
    public enum KeychainError: Error, LocalizedError {
        case unexpectedStatus(OSStatus)

        public var errorDescription: String? {
            switch self {
            case .unexpectedStatus(let status):
                let message = SecCopyErrorMessageString(status, nil) as String? ?? "Unknown Keychain error"
                return "Keychain error (\(status)): \(message)"
            }
        }
    }

    private let servicePrefix: String

    public init(servicePrefix: String = "com.seratotools.recordpool") {
        self.servicePrefix = servicePrefix
    }

    private func service(for pool: RecordPool) -> String {
        "\(servicePrefix).\(pool.rawValue)"
    }

    /// Saves (or replaces) the credentials for a pool.
    public func save(_ credentials: RecordPoolCredentials, for pool: RecordPool) throws {
        try remove(for: pool)

        guard let passwordData = credentials.password.data(using: .utf8) else {
            throw KeychainError.unexpectedStatus(errSecParam)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: pool),
            kSecAttrAccount as String: credentials.username,
            kSecValueData as String: passwordData,
            kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked,
        ]

        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }
    }

    /// Returns the stored credentials for a pool, or `nil` when none exist.
    public func credentials(for pool: RecordPool) throws -> RecordPoolCredentials? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: pool),
            kSecReturnAttributes as String: true,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        if status == errSecItemNotFound {
            return nil
        }
        guard status == errSecSuccess else {
            throw KeychainError.unexpectedStatus(status)
        }

        guard
            let dict = item as? [String: Any],
            let username = dict[kSecAttrAccount as String] as? String,
            let passwordData = dict[kSecValueData as String] as? Data,
            let password = String(data: passwordData, encoding: .utf8)
        else {
            return nil
        }

        return RecordPoolCredentials(username: username, password: password)
    }

    /// Whether a pool has stored credentials (cheap existence check).
    public func hasCredentials(for pool: RecordPool) -> Bool {
        (try? credentials(for: pool)) != nil
    }

    /// Removes the stored credentials for a pool. No-op when none exist.
    public func remove(for pool: RecordPool) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service(for: pool),
        ]

        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainError.unexpectedStatus(status)
        }
    }
}
