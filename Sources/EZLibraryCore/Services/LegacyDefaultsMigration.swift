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

/// Carries settings across the preference domains this app has written to.
///
/// `UserDefaults.standard` keys off the bundle identifier for a packaged app
/// (`com.seratotools.app`) and off the executable name for a plain binary
/// (`EZLibrary` under `swift run`), and the project was previously called
/// SeratoTools. The same person therefore ends up with API keys and preferences
/// in up to three separate plists, and whichever build they launch sees only
/// its own.
///
/// The symptom is not an error, it is worse: settings that look saved but have
/// no effect. A key entered in one build leaves the other reporting "no API
/// key", and an engine choice made in one silently falls back to the default in
/// the other.
public enum LegacyDefaultsMigration {
    /// Domains this app has historically written to, in the order they should
    /// be consulted — most recent naming first.
    public static let legacyDomainNames = ["EZLibrary", "SeratoTools"]

    /// Every setting this app owns is prefixed, so the prefix is the rule
    /// rather than a list that has to be kept in step with new settings.
    public static let keyPrefix = "SeratoTools"

    /// Set once the migration has run, so a value the user deliberately
    /// cleared does not reappear on the next launch.
    static let completionMarker = "SeratoToolsLegacyDefaultsMigrated"

    /// Copies settings from the legacy domains into `defaults`, without
    /// overwriting anything already there.
    ///
    /// Returns the keys it adopted, which the caller may log or surface.
    @discardableResult
    public static func migrateIfNeeded(
        from domains: [String] = legacyDomainNames,
        into defaults: UserDefaults = .standard,
        contentsOfDomain: ((String) -> [String: Any]?)? = nil
    ) -> [String] {
        guard !defaults.bool(forKey: completionMarker) else { return [] }
        defer { defaults.set(true, forKey: completionMarker) }
        return migrate(from: domains, into: defaults, contentsOfDomain: contentsOfDomain)
    }

    /// The copy itself, without the run-once guard.
    ///
    /// - Parameter contentsOfDomain: How a legacy domain is read. Injectable so
    ///   tests can supply fixtures instead of creating real preference domains:
    ///   a named domain is a file in `~/Library/Preferences` that survives
    ///   `removePersistentDomain`, and the daemon can rewrite it after
    ///   deletion, so tests that touch one cannot reliably clean up after
    ///   themselves.
    @discardableResult
    public static func migrate(
        from domains: [String] = legacyDomainNames,
        into defaults: UserDefaults = .standard,
        contentsOfDomain: ((String) -> [String: Any]?)? = nil
    ) -> [String] {
        let readDomain = contentsOfDomain ?? { defaults.persistentDomain(forName: $0) }

        var adopted: [String] = []
        for domain in domains {
            guard let contents = readDomain(domain) else { continue }

            for (key, value) in contents where key.hasPrefix(keyPrefix) {
                // An earlier legacy domain wins over a later one, and anything
                // already set in the current domain wins over both.
                guard key != completionMarker,
                      defaults.object(forKey: key) == nil,
                      !adopted.contains(key) else {
                    continue
                }
                defaults.set(value, forKey: key)
                adopted.append(key)
            }
        }
        return adopted
    }
}
