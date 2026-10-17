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

/// Repairs titles from record pools that stamp the whole filename into the
/// title tag, e.g. `Time - Edit - Main - Hot Since 82, Kuuda - 124 - 10A`.
///
/// Such a title is recognised by its trailing ` - <bpm> - <key>`. The real
/// title is whatever precedes the pool's version label (`Main`, `Extended`, …)
/// or, failing that, the artist credit. A title that doesn't look like this is
/// returned untouched, so correctly tagged files are never altered.
public enum PoolTitleCleaner {
    /// Version labels pools put between title and artist. `Main` is the
    /// default and carries no information, so it is dropped; the others are
    /// kept as `(Extended)` because a DJ cares which cut they have.
    private static let versions: [String: String?] = [
        "main": nil, "original": nil, "original mix": nil,
        "extended": "Extended", "extended mix": "Extended Mix",
        "radio edit": "Radio Edit", "radio": "Radio",
        "clean": "Clean", "dirty": "Dirty", "intro": "Intro",
        "short": "Short", "instrumental": "Instrumental",
        "acapella": "Acapella", "club mix": "Club Mix"
    ]

    private static let separator = " - "

    /// The cleaned title, or `title` unchanged when it isn't a pool-style one.
    public static func clean(title: String, artist: String?) -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        // Built per call: a shared static Regex isn't Sendable under Swift 6.
        let bpmAndKey = #/^(?<rest>.+) - (?<bpm>\d{2,3}) - (?<key>\d{1,2}[ABab]|[A-Ga-g][#b♯♭]?m?)$/#
        guard let match = trimmed.wholeMatch(of: bpmAndKey) else { return title }

        var parts = String(match.rest).components(separatedBy: separator)

        // Peel the artist credit off the end when it matches the artist tag.
        if parts.count > 1, let artist, fold(parts.last ?? "") == fold(artist) {
            parts.removeLast()
        }

        var version: String?
        if parts.count > 1, let label = versions[fold(parts.last ?? "")] {
            version = label
            parts.removeLast()
        } else if parts.count > 1, let index = parts.lastIndex(where: { versions.keys.contains(fold($0)) }) {
            // The artist credit didn't match the tag (credits get reformatted),
            // so anchor on the version label instead.
            version = versions[fold(parts[index])] ?? nil
            parts.removeSubrange(index...)
        }

        let base = parts.joined(separator: separator).trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else { return title }
        return version.map { "\(base) (\($0))" } ?? base
    }

    private static func fold(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}
