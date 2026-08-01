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

/// Formats track filenames from a user-configurable template string.
///
/// **Tokens** (case-sensitive, wrapped in `{}`):
/// - `{artist}`, `{title}`, `{album}`, `{year}`, `{bpm}`, `{key}`, `{genre}`
///
/// Empty fields are removed along with any adjacent duplicate separator
/// characters so the result never contains stray dashes or underscores.
///
/// Example template `{artist}-{title}-{album}-{year}` on a track with no
/// album renders `Disclosure-Latch-2012`, not `Disclosure-Latch--2012`.
public enum TrackFilenameFormatter {

    // MARK: - Public token catalogue

    public enum Token: String, CaseIterable, Sendable {
        case artist = "{artist}"
        case title  = "{title}"
        case album  = "{album}"
        case year   = "{year}"
        case bpm    = "{bpm}"
        case key    = "{key}"
        case genre  = "{genre}"

        /// Human-readable label shown in the settings UI.
        public var displayName: String {
            switch self {
            case .artist: return "Artist"
            case .title:  return "Title"
            case .album:  return "Album"
            case .year:   return "Year"
            case .bpm:    return "BPM"
            case .key:    return "Key"
            case .genre:  return "Genre"
            }
        }
    }

    // MARK: - Rename proposal

    public struct RenameProposal: Sendable {
        public let track: Track
        /// The absolute URL the file should be moved to. `nil` when the
        /// rendered filename is identical to the current filename (no-op).
        public let proposedURL: URL?
        public let warnings: [Warning]

        public var hasWarnings: Bool { !warnings.isEmpty }
        public var isNoOp: Bool { proposedURL == nil }
    }

    public enum Warning: Sendable, Equatable {
        case missingArtist
        case missingTitle
        case fileConflict(existingURL: URL)
    }

    // MARK: - Core rendering

    /// Renders the filename stem (no extension) for `track` using `template`.
    /// Returns an empty string only when every token in the template resolves
    /// to an empty value.
    public static func renderStem(for track: Track, template: String) -> String {
        var result = template

        let bpmString = track.bpm.map { String(format: "%.0f", $0) } ?? ""

        result = result.replacingOccurrences(of: Token.artist.rawValue, with: sanitize(track.artist))
        result = result.replacingOccurrences(of: Token.title.rawValue,  with: sanitize(track.title))
        result = result.replacingOccurrences(of: Token.album.rawValue,  with: sanitize(track.album))
        result = result.replacingOccurrences(of: Token.year.rawValue,   with: track.year.map(String.init) ?? "")
        result = result.replacingOccurrences(of: Token.bpm.rawValue,    with: bpmString)
        result = result.replacingOccurrences(of: Token.key.rawValue,    with: sanitize(track.key ?? ""))
        result = result.replacingOccurrences(of: Token.genre.rawValue,  with: sanitize(track.genre))

        return collapseEmptyTokenGaps(result)
    }

    /// Builds a `RenameProposal` for `track` against `template`, checking for
    /// file conflicts in the same directory.
    public static func propose(
        for track: Track,
        template: String
    ) -> RenameProposal {
        var warnings: [Warning] = []

        if track.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append(.missingArtist)
        }
        if track.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            warnings.append(.missingTitle)
        }

        let stem = renderStem(for: track, template: template)
        guard !stem.isEmpty else {
            // Nothing to render — treat as no-op with both warnings already set.
            return RenameProposal(track: track, proposedURL: nil, warnings: warnings)
        }

        let ext = track.fileURL.pathExtension
        let directory = track.fileURL.deletingLastPathComponent()
        var candidate = directory.appendingPathComponent(stem)
        if !ext.isEmpty { candidate.appendPathExtension(ext) }

        // No-op when the computed name already matches the current filename.
        if candidate.lastPathComponent == track.fileURL.lastPathComponent {
            return RenameProposal(track: track, proposedURL: nil, warnings: warnings)
        }

        // Detect conflict: a *different* file already sits at the target path.
        let fm = FileManager.default
        if fm.fileExists(atPath: candidate.path) {
            let isSelf = (try? fm.contentsEqual(atPath: candidate.path, andPath: track.fileURL.path)) ?? false
            if !isSelf {
                warnings.append(.fileConflict(existingURL: candidate))
            }
        }

        return RenameProposal(track: track, proposedURL: candidate, warnings: warnings)
    }

    // MARK: - Private helpers

    /// Strips characters that are forbidden in macOS filenames and collapses
    /// runs of whitespace. Does **not** strip separator characters like `-`
    /// because those are intentional parts of the template.
    private static func sanitize(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "" }

        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|")
        let cleaned = trimmed.unicodeScalars.map { scalar -> Character in
            if forbidden.contains(scalar) || scalar.value < 32 { return "-" }
            return Character(scalar)
        }

        var normalized = String(cleaned)
            .replacingOccurrences(of: "\t", with: " ")
            .replacingOccurrences(of: "\n", with: " ")

        while normalized.contains("  ") {
            normalized = normalized.replacingOccurrences(of: "  ", with: " ")
        }

        return normalized.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Collapses repeated separator characters that appear when tokens render
    /// to empty strings, then trims leading/trailing separators.
    ///
    /// Handles `{artist}-{title}-{album}` → `Artist--Album` → `Artist-Album`
    /// as well as ` - ` spaced variants.
    private static func collapseEmptyTokenGaps(_ value: String) -> String {
        var result = value

        // Collapse multi-char spaced separators first (e.g. " -  - " → " - ")
        // before collapsing bare dashes so we don't double-collapse.
        let spacedPatterns = [" - - ", " -  - ", "  -  "]
        for pattern in spacedPatterns {
            while result.contains(pattern) {
                result = result.replacingOccurrences(of: pattern, with: " - ")
            }
        }

        // Collapse bare repeated separators
        for sep in ["-", "_"] {
            while result.contains(sep + sep) {
                result = result.replacingOccurrences(of: sep + sep, with: sep)
            }
        }

        // Collapse multiple spaces
        while result.contains("  ") {
            result = result.replacingOccurrences(of: "  ", with: " ")
        }

        return result.trimmingCharacters(in: CharacterSet(charactersIn: "-_ "))
    }
}
