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
///
/// Nothing here touches a real preference domain. Legacy domains are supplied
/// as fixtures and the destination is in-memory, so the tests leave no files
/// behind — a named domain outlives `removePersistentDomain`, and the
/// preferences daemon can rewrite its file after deletion, so a test that
/// creates one cannot reliably clean up after itself.
private func fixtureReader(_ domains: [String: [String: Any]]) -> (String) -> [String: Any]? {
    { domains[$0] }
}

@Test func settingsFromALegacyDomainAreAdopted() {
    let defaults = TestDefaults.inMemory()

    let adopted = LegacyDefaultsMigration.migrate(
        from: ["Legacy"],
        into: defaults,
        contentsOfDomain: fixtureReader([
            "Legacy": [
                "SeratoToolsAnthropicKey": "sk-legacy",
                "SeratoToolsTagVerificationEngine": "cloudModel"
            ]
        ])
    )

    #expect(Set(adopted) == ["SeratoToolsAnthropicKey", "SeratoToolsTagVerificationEngine"])
    #expect(defaults.string(forKey: "SeratoToolsAnthropicKey") == "sk-legacy")
    #expect(defaults.string(forKey: "SeratoToolsTagVerificationEngine") == "cloudModel")
}

@Test func existingSettingsAreNeverOverwritten() {
    let defaults = TestDefaults.inMemory()
    defaults.set("sk-current", forKey: "SeratoToolsAnthropicKey")

    let adopted = LegacyDefaultsMigration.migrate(
        from: ["Legacy"],
        into: defaults,
        contentsOfDomain: fixtureReader(["Legacy": ["SeratoToolsAnthropicKey": "sk-legacy"]])
    )

    #expect(adopted.isEmpty)
    #expect(defaults.string(forKey: "SeratoToolsAnthropicKey") == "sk-current")
}

@Test func unrelatedKeysAreLeftBehind() {
    let defaults = TestDefaults.inMemory()

    let adopted = LegacyDefaultsMigration.migrate(
        from: ["Legacy"],
        into: defaults,
        contentsOfDomain: fixtureReader([
            "Legacy": ["SeratoToolsDiscogsToken": "keep", "NSSomeAppleInternalThing": "drop"]
        ])
    )

    #expect(adopted == ["SeratoToolsDiscogsToken"])
    #expect(defaults.object(forKey: "NSSomeAppleInternalThing") == nil)
}

@Test func theEarlierDomainWinsWhenBothCarryTheSameKey() {
    let defaults = TestDefaults.inMemory()

    _ = LegacyDefaultsMigration.migrate(
        from: ["Newer", "Older"],
        into: defaults,
        contentsOfDomain: fixtureReader([
            "Newer": ["SeratoToolsAcoustIDKey": "newer"],
            "Older": ["SeratoToolsAcoustIDKey": "older"]
        ])
    )

    #expect(defaults.string(forKey: "SeratoToolsAcoustIDKey") == "newer")
}

@Test func migrationRunsOnlyOnceSoClearedSettingsStayCleared() {
    let defaults = TestDefaults.inMemory()
    let reader = fixtureReader(["Legacy": ["SeratoToolsDiscogsToken": "legacy"]])

    #expect(LegacyDefaultsMigration.migrateIfNeeded(
        from: ["Legacy"], into: defaults, contentsOfDomain: reader
    ).count == 1)

    // The user then clears it deliberately; a second launch must not resurrect it.
    defaults.removeObject(forKey: "SeratoToolsDiscogsToken")
    #expect(LegacyDefaultsMigration.migrateIfNeeded(
        from: ["Legacy"], into: defaults, contentsOfDomain: reader
    ).isEmpty)
    #expect(defaults.object(forKey: "SeratoToolsDiscogsToken") == nil)
}

@Test func aMissingLegacyDomainIsNotAnError() {
    let defaults = TestDefaults.inMemory()
    #expect(LegacyDefaultsMigration.migrate(
        from: ["Absent"], into: defaults, contentsOfDomain: fixtureReader([:])
    ).isEmpty)
}

@Test func theRealMigrationReadsActualPreferenceDomains() {
    // The injected reader is a test seam, so one case confirms the production
    // default still goes through `persistentDomain(forName:)`.
    let defaults = TestDefaults.inMemory()
    #expect(LegacyDefaultsMigration.migrate(
        from: ["a-domain-that-does-not-exist-\(UUID().uuidString)"],
        into: defaults
    ).isEmpty)
}
