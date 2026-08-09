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

/// Finds tracks whose tag values carry leading or trailing whitespace, and
/// builds the updates that clean them.
///
/// New writes are already normalised by `SeratoTrackMetadataUpdate`, so this
/// exists for tags written before that — or by other software. Padding is
/// invisible in the field but splits an artist in two everywhere Serato
/// compares or sorts on the value.
///
/// The cleanup itself is just a re-save: building an update from a track's
/// current values runs them through the same normalising type, so the trimmed
/// form is what reaches the database and the file's ID3 frames.
public enum TagWhitespaceCleanupService {
    /// One track needing cleanup, plus the fields that are padded.
    public struct Finding: Sendable, Identifiable {
        public let track: Track
        /// Display names of the affected fields, e.g. `["Artist", "Title"]`.
        public let fields: [String]

        public var id: UUID { track.id }

        public init(track: Track, fields: [String]) {
            self.track = track
            self.fields = fields
        }
    }

    /// The tag fields this can clean — the ones `SeratoTrackMetadataUpdate`
    /// can write. `grouping` and `label` are parsed but not writable, so
    /// reporting them would promise a fix that never lands.
    private static func paddedFields(of track: Track) -> [String] {
        var fields: [String] = []
        let candidates: [(name: String, value: String)] = [
            ("Title", track.title),
            ("Artist", track.artist),
            ("Album", track.album),
            ("Genre", track.genre),
            ("Comment", track.comment),
            ("Key", track.key ?? "")
        ]

        for candidate in candidates {
            let trimmed = SeratoTrackMetadataUpdate.trimmed(candidate.value)
            // A field that is nothing *but* whitespace is left alone: trimming
            // it to empty would erase a value rather than tidy one, and that
            // isn't what a cleanup should silently do.
            guard trimmed != candidate.value, !trimmed.isEmpty else { continue }
            fields.append(candidate.name)
        }
        return fields
    }

    /// Scans `tracks` for padded tag values. Pure and cheap — no file access,
    /// it reads what `database V2` already gave us.
    public static func findings(in tracks: [Track]) -> [Finding] {
        tracks.compactMap { track in
            let fields = paddedFields(of: track)
            return fields.isEmpty ? nil : Finding(track: track, fields: fields)
        }
    }

    /// The update that cleans one track. Values are passed through verbatim;
    /// `SeratoTrackMetadataUpdate` does the trimming.
    public static func cleanedUpdate(for track: Track) -> SeratoTrackMetadataUpdate {
        SeratoTrackMetadataUpdate(
            title: track.title,
            artist: track.artist,
            album: track.album,
            genre: track.genre,
            comment: track.comment,
            key: track.key ?? "",
            bpm: track.bpm,
            year: track.year
        )
    }

    /// Ready-to-apply pairs for the existing batch metadata writer.
    public static func updates(for findings: [Finding]) -> [(Track, SeratoTrackMetadataUpdate)] {
        findings.map { ($0.track, cleanedUpdate(for: $0.track)) }
    }

    /// One-line summary for the confirmation prompt.
    public static func summary(for findings: [Finding]) -> String {
        guard !findings.isEmpty else {
            return "No tags need cleaning — nothing has leading or trailing spaces."
        }

        var fieldCounts: [String: Int] = [:]
        for finding in findings {
            for field in finding.fields {
                fieldCounts[field, default: 0] += 1
            }
        }
        let breakdown = fieldCounts
            .sorted { $0.value == $1.value ? $0.key < $1.key : $0.value > $1.value }
            .map { "\($0.key) (\($0.value))" }
            .joined(separator: ", ")

        let count = findings.count
        let subject = count == 1 ? "1 track has" : "\(count) tracks have"
        return "\(subject) tag values padded with spaces: \(breakdown)."
    }
}
