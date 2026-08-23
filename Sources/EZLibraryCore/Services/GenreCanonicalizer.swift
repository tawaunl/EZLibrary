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

/// Settles on one spelling per genre, and says which genres are electronic.
///
/// The sources do not agree on how to write a genre even when they agree on
/// what it is: iTunes says "Hip-Hop/Rap", Deezer says "Rap/Hip Hop",
/// MusicBrainz says "hip hop". Written through verbatim they produce three
/// different genres in a library that should have one, and they also stop the
/// consensus engine from seeing that all three sources agreed.
///
/// The electronic question is separate and exists for the year rule: a remix of
/// a non-electronic record is tagged with the original song's year, while in
/// electronic music a remix is its own release with its own year.
public enum GenreCanonicalizer {
    /// Canonical spellings, keyed by a normalised form of what a source said.
    ///
    /// Deliberately short. Every entry is a case where the sources genuinely
    /// disagree on spelling for the same genre — this is not a place to impose
    /// a taxonomy on someone's library.
    static let canonicalSpellings: [String: String] = {
        var map: [String: String] = [:]
        for variant in [
            "hip hop", "hiphop", "hip hop rap", "rap hip hop", "hip hop and rap",
            "rap and hip hop", "rap", "hip hop music", "rap music"
        ] {
            map[variant] = "Hip Hop"
        }
        for variant in ["r and b", "rnb", "r b", "rhythm and blues", "r b soul", "soul r b"] {
            map[variant] = "R&B"
        }
        for variant in ["drum and bass", "drum n bass", "dnb", "drum bass"] {
            map[variant] = "Drum & Bass"
        }
        return map
    }()

    /// Genres that count as electronic for the year rule.
    static let electronicGenres: Set<String> = [
        "electronic", "electronica", "electro", "dance", "edm", "club",
        "house", "deep house", "tech house", "progressive house", "future house",
        "afro house", "melodic house", "bass house", "electro house",
        "techno", "minimal techno", "trance", "psytrance", "hard dance", "hardstyle",
        "drum and bass", "drum n bass", "dnb", "jungle", "dubstep", "bass",
        "breakbeat", "breaks", "garage", "uk garage", "2 step", "ambient", "idm",
        "downtempo", "trip hop", "nu disco", "disco house", "big room", "eurodance"
    ]

    /// The spelling this library should store for `rawGenre`.
    ///
    /// A genre with no known variant is returned trimmed but otherwise as the
    /// source wrote it — inventing a canonical form for everything would mean
    /// rewriting genres the user chose deliberately.
    public static func canonical(_ rawGenre: String) -> String {
        let trimmed = rawGenre.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }
        return canonicalSpellings[normalizedKey(trimmed)] ?? trimmed
    }

    /// True when the genre belongs to the electronic family.
    ///
    /// Checks the canonical form first, then falls back to a substring match so
    /// "Progressive House / Melodic Techno" is recognised without every
    /// combination being listed.
    public static func isElectronic(_ rawGenre: String) -> Bool {
        let key = normalizedKey(canonical(rawGenre))
        guard !key.isEmpty else { return false }
        if electronicGenres.contains(key) { return true }
        return electronicGenres.contains { key.contains($0) }
    }

    /// Lower-cased, punctuation collapsed to single spaces, so "Hip-Hop/Rap",
    /// "hip hop & rap" and "Hip Hop / Rap" all reduce to the same key.
    static func normalizedKey(_ value: String) -> String {
        let folded = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        let collapsed = folded
            .replacingOccurrences(of: "&", with: " and ")
            .replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
        return collapsed.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }
}
