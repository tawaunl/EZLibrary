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

/// Record pools often stamp their own name into tags that should describe the
/// music — most commonly the album ("ID By Rivoli", "BPM Supreme"), sometimes
/// a trailing "(DJcity)" on the title. This removes those placeholders.
///
/// Matching is on the whole value (after ignoring case, spacing and
/// punctuation), never a substring, so a real album that merely mentions a
/// pool name is kept.
public enum PoolPlaceholderFilter {
    /// Pool names, written naturally; matching normalises them.
    private static let poolNames = [
        "ID By Rivoli", "BPM Supreme", "DJcity", "DJ City", "Beat Junkies",
        "MyMP3Pool", "Heavy Hits", "Digital DJ Pool", "Club Killers",
        "Crooklyn Clan", "Promo Only", "Zip DJ", "Franchise Record Pool",
        "Hype Pool", "Direct Music Service", "Smashvision", "Redrum",
        "Southern Fresh", "Mixed In Key Pool", "DJ Remix Pool"
    ]

    private static let normalizedPools: Set<String> = Set(poolNames.map(normalize))

    public static func isPlaceholder(_ value: String) -> Bool {
        normalizedPools.contains(normalize(value))
    }

    /// `nil` when the value is only a pool name; otherwise unchanged.
    public static func cleanedTag(_ value: String?) -> String? {
        guard let value, !isPlaceholder(value) else { return nil }
        return value
    }

    private static let promoLeads = [
        "downloaded from", "download from", "from", "via", "provided by", "promo",
        "exclusive", "courtesy of", "www.", "http"
    ]

    /// A comment is free text, so pieces are judged one at a time (split on
    /// `|`, `/`, `;`, `•` and newlines): a piece is dropped when it is only a
    /// pool name, or a promo line such as "Downloaded from BPM Supreme" or a
    /// pool URL. Anything else the pool wrote is kept. `nil` if nothing is left.
    public static func cleanedComment(_ value: String?) -> String? {
        guard let value else { return nil }
        let pieces = value.components(separatedBy: CharacterSet(charactersIn: "|/;•\n\r"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let kept = pieces.filter { piece in
            if isPlaceholder(piece) { return false }
            let folded = normalize(piece)
            let mentionsPool = normalizedPools.contains { folded.contains($0) }
            let lowered = piece.lowercased()
            return !(mentionsPool && promoLeads.contains { lowered.hasPrefix($0) })
        }
        return kept.isEmpty ? nil : kept.joined(separator: " | ")
    }

    /// Drops a trailing `(Pool)` / `[Pool]` / `- Pool` decoration from a title.
    public static func strippingTrailingPoolTag(from title: String) -> String {
        var result = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let bracketed = #/^(?<head>.+?)\s*[\(\[](?<tag>[^\)\]]+)[\)\]]$/#
        if let match = result.wholeMatch(of: bracketed), isPlaceholder(String(match.tag)) {
            result = String(match.head)
        } else if let range = result.range(of: " - ", options: .backwards),
                  isPlaceholder(String(result[range.upperBound...])) {
            result = String(result[..<range.lowerBound])
        }
        return result.isEmpty ? title : result
    }

    private static func normalize(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
            .filter { $0.isLetter || $0.isNumber }
    }
}
