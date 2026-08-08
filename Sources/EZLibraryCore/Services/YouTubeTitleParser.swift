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

/// Pulls an artist and title out of a YouTube video title.
///
/// Music uploads almost universally follow `Artist - Title`, with the format
/// decoration channels like to append (`(Official Video)`, `[HD]`, …). The
/// channel name is *not* the artist — "E40TV" uploads E-40 records, "WorldstarHipHop"
/// uploads everyone's — so trusting `uploader` puts the wrong name in the tags
/// and, once auto-rename runs, in the filename too.
///
/// Anything this can't parse confidently comes back with an empty artist. That
/// is deliberate: an empty field is honest and easy to fill in later, while a
/// wrong one silently corrupts both the tag and the file name.
public enum YouTubeTitleParser {
    public struct ParsedTitle: Sendable, Equatable {
        /// Empty when no artist could be read out of the title.
        public let artist: String
        public let title: String

        public init(artist: String, title: String) {
            self.artist = artist
            self.title = title
        }
    }

    /// Separators between artist and title, in priority order. All are
    /// space-padded on purpose: an unpadded hyphen is part of a name
    /// ("E-40", "Jay-Z", "T-Pain"), not a separator.
    private static let separators = [" - ", " – ", " — ", " ‒ ", " ― "]

    /// Bracketed decorations to drop. Matched only when one of these is the
    /// *entire* contents of the bracket, so DJ-meaningful annotations —
    /// `(Dirty)`, `(Clean)`, `(Intro)`, `(Extended Mix)`, `(feat. …)` — survive.
    private static let noiseTerms: Set<String> = [
        "official video", "official music video", "official audio",
        "official lyric video", "official lyrics video", "official visualizer",
        "official video hd", "official", "music video", "lyric video",
        "lyrics video", "lyrics", "lyric", "audio", "visualizer", "visualiser",
        "hd", "hq", "4k", "8k", "full hd", "high quality", "explicit",
        "explicit version", "official trailer", "video oficial", "new"
    ]

    /// Splits `videoTitle` into artist and title.
    ///
    /// `uploader` is accepted but used only as a sanity check — never as the
    /// artist. If the title's left-hand side is just the channel name repeated,
    /// there's no real artist there to take.
    public static func parse(videoTitle: String, uploader: String? = nil) -> ParsedTitle {
        let cleaned = stripNoise(videoTitle)
        guard !cleaned.isEmpty else {
            return ParsedTitle(artist: "", title: trimmed(videoTitle))
        }

        guard let split = splitOnFirstSeparator(cleaned) else {
            return ParsedTitle(artist: "", title: cleaned)
        }

        let artist = unwrapQuotes(split.left)
        let title = unwrapQuotes(split.right)

        // "Artist - " or " - Title" isn't a real split.
        guard !artist.isEmpty, !title.isEmpty else {
            return ParsedTitle(artist: "", title: cleaned)
        }

        // Channels that title their uploads "ChannelName - Some Song" give us
        // the channel again, which is the exact thing we're trying to avoid.
        if let uploader, normalized(uploader) == normalized(artist) {
            return ParsedTitle(artist: "", title: title)
        }

        return ParsedTitle(artist: artist, title: title)
    }

    // MARK: - Cleaning

    /// Removes bracketed format decorations, leaving meaningful ones in place.
    static func stripNoise(_ value: String) -> String {
        var result = ""
        var depth = 0
        var buffer = ""

        for character in value {
            if character == "(" || character == "[" {
                if depth == 0 {
                    buffer = ""
                } else {
                    buffer.append(character)
                }
                depth += 1
                continue
            }

            if character == ")" || character == "]" {
                depth = max(0, depth - 1)
                if depth == 0 {
                    // Kept groups are re-emitted with parens, since the
                    // original bracket style carries no meaning.
                    if !noiseTerms.contains(normalizedTerm(buffer)) {
                        result += "(\(trimmed(buffer)))"
                    }
                    buffer = ""
                } else {
                    buffer.append(character)
                }
                continue
            }

            if depth > 0 {
                buffer.append(character)
            } else {
                result.append(character)
            }
        }

        // An unbalanced opening bracket leaves text stranded in the buffer;
        // keep it rather than silently dropping part of the title.
        if depth > 0, !trimmed(buffer).isEmpty {
            result += " " + trimmed(buffer)
        }

        return collapseWhitespace(result)
    }

    private static func splitOnFirstSeparator(_ value: String) -> (left: String, right: String)? {
        var best: (range: Range<String.Index>, index: String.Index)?

        for separator in separators {
            guard let range = value.range(of: separator) else { continue }
            if best == nil || range.lowerBound < best!.index {
                best = (range, range.lowerBound)
            }
        }

        guard let best else { return nil }
        return (
            trimmed(String(value[value.startIndex..<best.range.lowerBound])),
            trimmed(String(value[best.range.upperBound...]))
        )
    }

    /// Channels often quote the song: `Artist - "Title"`.
    private static func unwrapQuotes(_ value: String) -> String {
        let quotePairs: [(Character, Character)] = [("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’")]
        var result = trimmed(value)

        for (open, close) in quotePairs where result.count >= 2 {
            if result.first == open, result.last == close {
                result = trimmed(String(result.dropFirst().dropLast()))
                break
            }
        }
        return result
    }

    // MARK: - Normalising

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func collapseWhitespace(_ value: String) -> String {
        trimmed(value.replacingOccurrences(
            of: "\\s+", with: " ", options: .regularExpression))
    }

    /// Lowercased, punctuation-stripped form used to match noise terms, so
    /// `[OFFICIAL VIDEO]` and `(official video.)` both match.
    private static func normalizedTerm(_ value: String) -> String {
        collapseWhitespace(trimmed(value).lowercased()
            .replacingOccurrences(of: "[^a-z0-9 ]", with: "", options: .regularExpression))
    }

    /// Aggressive form used only to compare an artist against a channel name.
    private static func normalized(_ value: String) -> String {
        value.lowercased().replacingOccurrences(
            of: "[^a-z0-9]", with: "", options: .regularExpression)
    }
}
