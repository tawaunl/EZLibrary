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
import Testing
@testable import EZLibraryCore

/// The bug these cover, observed on a real machine: an API key and an engine
/// choice saved under the `EZLibrary` domain while the packaged app read
/// `com.seratotools.app`, so the app reported no key and silently ran the free
/// engine instead of the cloud one the user had selected.

/// Reads a key straight out of one domain.
///
/// `UserDefaults.string(forKey:)` searches a whole list — suite, then the
/// process's own application domain, then globals — and under `swift test` that
/// application domain resolves to `EZLibrary`, the very domain holding the real
/// settings these tests are about. Asserting through the search list therefore
/// picked up the machine's actual API keys instead of the fixture. Every read
/// here names the domain explicitly.
/// Keys here are deliberately fixtures (`SeratoToolsFixture…`) rather than the
/// real setting names. They share the migrated prefix, so the logic under test
/// is identical, but they cannot collide with the machine's actual saved keys —
/// which the real names did, because the migration's "already set?" check reads
/// through the whole domain search list and found the user's own Discogs and
/// AcoustID values.
private func value(_ key: String, inDomain domain: String) -> String? {
    UserDefaults.standard.persistentDomain(forName: domain)?[key] as? String
}

private func seed(_ contents: [String: String], intoDomain domain: String) {
    UserDefaults.standard.setPersistentDomain(contents, forName: domain)
}

private func scratchDefaults() -> (UserDefaults, String) {
    let suite = "MigrationTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

@Test func settingsFromALegacyDomainAreAdopted() {
    let legacy = "MigrationLegacy-\(UUID().uuidString)"
    let (defaults, suite) = scratchDefaults()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        UserDefaults.standard.removePersistentDomain(forName: legacy)
    }

    seed(["SeratoToolsFixtureAlpha": "sk-legacy", "SeratoToolsFixtureBeta": "cloudModel"],
         intoDomain: legacy)

    let adopted = LegacyDefaultsMigration.migrate(from: [legacy], into: defaults)

    #expect(Set(adopted) == ["SeratoToolsFixtureAlpha", "SeratoToolsFixtureBeta"])
    #expect(value("SeratoToolsFixtureAlpha", inDomain: suite) == "sk-legacy")
    #expect(value("SeratoToolsFixtureBeta", inDomain: suite) == "cloudModel")
}

@Test func existingSettingsAreNeverOverwritten() {
    let legacy = "MigrationLegacy-\(UUID().uuidString)"
    let (defaults, suite) = scratchDefaults()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        UserDefaults.standard.removePersistentDomain(forName: legacy)
    }

    defaults.set("sk-current", forKey: "SeratoToolsFixtureAlpha")
    seed(["SeratoToolsFixtureAlpha": "sk-legacy"], intoDomain: legacy)

    let adopted = LegacyDefaultsMigration.migrate(from: [legacy], into: defaults)
    #expect(adopted.isEmpty)
    #expect(value("SeratoToolsFixtureAlpha", inDomain: suite) == "sk-current")
}

@Test func unrelatedKeysAreLeftBehind() {
    let legacy = "MigrationLegacy-\(UUID().uuidString)"
    let (defaults, suite) = scratchDefaults()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        UserDefaults.standard.removePersistentDomain(forName: legacy)
    }

    seed(["SeratoToolsFixtureGamma": "keep", "NSSomeAppleInternalThing": "drop"], intoDomain: legacy)

    let adopted = LegacyDefaultsMigration.migrate(from: [legacy], into: defaults)
    #expect(adopted == ["SeratoToolsFixtureGamma"])
    #expect(value("NSSomeAppleInternalThing", inDomain: suite) == nil)
}

@Test func theEarlierDomainWinsWhenBothCarryTheSameKey() {
    let first = "MigrationA-\(UUID().uuidString)"
    let second = "MigrationB-\(UUID().uuidString)"
    let (defaults, suite) = scratchDefaults()
    defer {
        for name in [suite, first, second] {
            UserDefaults.standard.removePersistentDomain(forName: name)
        }
    }

    seed(["SeratoToolsFixtureDelta": "newer"], intoDomain: first)
    seed(["SeratoToolsFixtureDelta": "older"], intoDomain: second)

    _ = LegacyDefaultsMigration.migrate(from: [first, second], into: defaults)
    #expect(value("SeratoToolsFixtureDelta", inDomain: suite) == "newer")
}

@Test func migrationRunsOnlyOnceSoClearedSettingsStayCleared() {
    let legacy = "MigrationLegacy-\(UUID().uuidString)"
    let (defaults, suite) = scratchDefaults()
    defer {
        UserDefaults.standard.removePersistentDomain(forName: suite)
        UserDefaults.standard.removePersistentDomain(forName: legacy)
    }

    seed(["SeratoToolsFixtureGamma": "legacy"], intoDomain: legacy)

    #expect(LegacyDefaultsMigration.migrateIfNeeded(from: [legacy], into: defaults).count == 1)

    // The user then clears it deliberately; a second launch must not resurrect it.
    defaults.removeObject(forKey: "SeratoToolsFixtureGamma")
    #expect(LegacyDefaultsMigration.migrateIfNeeded(from: [legacy], into: defaults).isEmpty)
    #expect(value("SeratoToolsFixtureGamma", inDomain: suite) == nil)
}

@Test func aMissingLegacyDomainIsNotAnError() {
    let (defaults, suite) = scratchDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }
    #expect(LegacyDefaultsMigration.migrate(from: ["NoSuchDomain-\(UUID().uuidString)"], into: defaults).isEmpty)
}
