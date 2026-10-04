// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Foundation
import Security

/// Where API keys live.
///
/// These used to be written straight into `UserDefaults`, which puts them in
/// cleartext in `~/Library/Preferences/com.seratotools.app.plist` — a file any
/// process running as the user can read, and one that gets swept into Time
/// Machine and iCloud backups. An Anthropic key carries billing, so it belongs
/// in the Keychain, where access is scoped to this signed app.
///
/// Reads fall back to the old defaults location and migrate on the way past, so
/// an existing install keeps working without the user re-entering anything.
public protocol SecureCredentialStore: Sendable {
    func value(for account: String) -> String?
    func setValue(_ value: String?, for account: String)
}

/// The real store, backed by the login keychain.
public struct KeychainCredentialStore: SecureCredentialStore {
    private let service: String

    public init(service: String = "com.seratotools.app") {
        self.service = service
    }

    private func query(for account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }

    public func value(for account: String) -> String? {
        var lookup = query(for: account)
        lookup[kSecReturnData as String] = true
        lookup[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(lookup as CFDictionary, &item)
        guard status == errSecSuccess,
              let data = item as? Data,
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    public func setValue(_ value: String?, for account: String) {
        let base = query(for: account)

        guard let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            SecItemDelete(base as CFDictionary)
            return
        }

        let data = Data(value.utf8)
        let update: [String: Any] = [kSecValueData as String: data]

        let status = SecItemUpdate(base as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var insert = base
            insert[kSecValueData as String] = data
            // The key is only needed while the user is at the machine, and it
            // should never ride along to another device in a keychain sync.
            insert[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            SecItemAdd(insert as CFDictionary, nil)
        }
    }
}

/// An in-memory stand-in so tests never touch the real login keychain.
public final class InMemoryCredentialStore: SecureCredentialStore, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init(_ initial: [String: String] = [:]) {
        storage = initial
    }

    public func value(for account: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let value = storage[account]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else { return nil }
        return value
    }

    public func setValue(_ value: String?, for account: String) {
        lock.lock()
        defer { lock.unlock() }
        if let value, !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            storage[account] = value
        } else {
            storage.removeValue(forKey: account)
        }
    }
}

public enum AppCredentials {
    /// The store the app uses. Tests substitute an `InMemoryCredentialStore`.
    public static let keychain: any SecureCredentialStore = KeychainCredentialStore()

    /// Every credential that used to live in `UserDefaults`, as
    /// (keychain account, legacy defaults key).
    public static let legacyMigrations: [(account: String, defaultsKey: String)] = [
        ("anthropic-api-key", "SeratoToolsAnthropicKey"),
        ("openai-compatible-api-key", "SeratoToolsOpenAICompatibleKey"),
        ("youtube-api-key", "SeratoToolsYouTubeAPIKey"),
        ("discogs-token", "SeratoToolsDiscogsToken"),
        ("acoustid-api-key", "SeratoToolsAcoustIDKey")
    ]

    /// Reads a credential. This is a **pure read**: it never writes anywhere.
    ///
    /// Reading used to migrate the legacy value as a side effect, which meant
    /// any code path that happened to want a token — including one reached
    /// from a test — wrote to the real login keychain. Migration is now a
    /// separate, deliberate step (`migrateLegacyCredentials`), so a read is
    /// only ever a read.
    public static func value(
        account: String,
        legacyDefaultsKey: String,
        store: any SecureCredentialStore,
        userDefaults: UserDefaults
    ) -> String? {
        if let value = store.value(for: account) {
            return value
        }
        // Still honoured so a build that hasn't migrated yet keeps working.
        guard let legacy = userDefaults.string(forKey: legacyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty else {
            return nil
        }
        return legacy
    }

    /// Writes a credential to the Keychain and clears any legacy copy.
    public static func store(
        _ value: String?,
        account: String,
        legacyDefaultsKey: String,
        store: any SecureCredentialStore,
        userDefaults: UserDefaults
    ) {
        store.setValue(value, for: account)
        userDefaults.removeObject(forKey: legacyDefaultsKey)
    }

    /// Moves any credentials still sitting in `UserDefaults` into the Keychain.
    /// Call once at launch.
    ///
    /// The defaults copy is removed only once the Keychain is confirmed to hold
    /// the value: if the Keychain write fails, a key the user can still use
    /// beats a key that silently vanished.
    @discardableResult
    public static func migrateLegacyCredentials(
        store: any SecureCredentialStore = keychain,
        userDefaults: UserDefaults = .standard
    ) -> Int {
        var migrated = 0
        for entry in legacyMigrations {
            guard let legacy = userDefaults.string(forKey: entry.defaultsKey)?
                .trimmingCharacters(in: .whitespacesAndNewlines), !legacy.isEmpty else {
                continue
            }
            // A keychain value already present wins; drop the stale plist copy.
            if store.value(for: entry.account) != nil {
                userDefaults.removeObject(forKey: entry.defaultsKey)
                continue
            }
            store.setValue(legacy, for: entry.account)
            if store.value(for: entry.account) != nil {
                userDefaults.removeObject(forKey: entry.defaultsKey)
                migrated += 1
            }
        }
        return migrated
    }
}
