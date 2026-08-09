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

/// Reads Serato's per-track play count.
///
/// Serato does not store the play count in the `database V2` file — it writes
/// it into the audio file's ID3 tag as a user-defined text frame
/// (`TXXX` with the description `SERATO_PLAYCOUNT`). Only the ID3 tag at the
/// start of the file is read (not the whole file), so this stays cheap enough
/// to run across a large library in the background.
public enum SeratoPlayCountReader {
    /// Descriptions to try, in priority order. `SERATO_PLAYCOUNT` is Serato's
    /// own frame; the `FMPS_*` variants are the cross-application fallbacks
    /// some tools write.
    private static let playCountDescriptions = ["SERATO_PLAYCOUNT", "FMPS_PLAYCOUNT", "FMPS_Playcount"]

    /// Returns the play count stored in the file's ID3 tag, or `nil` when the
    /// file is unsupported, has no ID3 tag, or carries no play-count frame.
    public static func playCount(forFileAt url: URL) -> Int? {
        guard url.pathExtension.lowercased() == "mp3" else { return nil }
        guard let tag = ID3ArtworkCodec.readID3TagBytes(at: url) else { return nil }

        for description in playCountDescriptions {
            guard let value = ID3ArtworkCodec.userTextValue(fromID3TagBytes: tag, description: description) else {
                continue
            }
            if let count = parseCount(value) {
                return count
            }
        }
        return nil
    }

    private static func parseCount(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Some tools store a decimal ("5.0"); accept the integer part.
        if let intValue = Int(trimmed) {
            return max(0, intValue)
        }
        if let doubleValue = Double(trimmed) {
            return max(0, Int(doubleValue))
        }
        return nil
    }
}
