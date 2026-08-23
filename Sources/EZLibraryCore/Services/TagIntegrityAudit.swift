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

/// Deterministic, offline checks for tags that are visibly wrong.
///
/// This is the first half of tag verification and it costs nothing: no network,
/// no API key, no file reads. It catches the damage that comes from the way DJ
/// libraries are actually assembled — record-pool downloads with the pool's
/// name stuffed into the comment, YouTube rips whose title is the whole video
/// heading, files whose tags were never filled in and whose real identity is
/// sitting in the filename.
///
/// What it deliberately does *not* do is guess the correct value. Deciding that
/// "Hotline Bling" is by Drake and came out in 2015 needs a source; that is
/// `AITagVerificationService`'s job. This narrows the field to the tracks worth
/// asking about, which is what keeps a whole-library pass affordable.
public enum TagIntegrityAudit {
    public enum Severity: Int, Sendable, Comparable {
        case low
        case medium
        case high

        public static func < (lhs: Severity, rhs: Severity) -> Bool {
            lhs.rawValue < rhs.rawValue
        }

        public var displayName: String {
            switch self {
            case .low:
                return "Low"
            case .medium:
                return "Medium"
            case .high:
                return "High"
            }
        }
    }

    /// The tag fields this audit reports on. Matches what
    /// `SeratoTrackMetadataUpdate` can actually write, so a finding never
    /// promises a fix that cannot be applied.
    public enum Field: String, Sendable, Hashable, CaseIterable {
        case title
        case artist
        case album
        case genre
        case year
        case comment

        public var displayName: String {
            rawValue.capitalized
        }
    }

    public struct Issue: Sendable, Hashable {
        public let field: Field
        public let severity: Severity
        /// One line, written for the person reading the review list.
        public let summary: String

        public init(field: Field, severity: Severity, summary: String) {
            self.field = field
            self.severity = severity
            self.summary = summary
        }
    }

    public struct Finding: Sendable, Identifiable {
        public let track: Track
        public let issues: [Issue]

        public var id: UUID { track.id }

        public var highestSeverity: Severity {
            issues.map(\.severity).max() ?? .low
        }

        /// The fields worth asking an outside source about.
        public var affectedFields: [Field] {
            var seen: [Field] = []
            for issue in issues where !seen.contains(issue.field) {
                seen.append(issue.field)
            }
            return seen
        }

        public init(track: Track, issues: [Issue]) {
            self.track = track
            self.issues = issues
        }
    }

    // MARK: - Entry points

    public static func findings(in tracks: [Track]) -> [Finding] {
        tracks.compactMap { track in
            let issues = audit(track)
            return issues.isEmpty ? nil : Finding(track: track, issues: issues)
        }
        .sorted { lhs, rhs in
            lhs.highestSeverity == rhs.highestSeverity
                ? lhs.track.fileURL.lastPathComponent < rhs.track.fileURL.lastPathComponent
                : lhs.highestSeverity > rhs.highestSeverity
        }
    }

    public static func audit(_ track: Track) -> [Issue] {
        var issues: [Issue] = []
        issues.append(contentsOf: missingFieldIssues(track))
        issues.append(contentsOf: placeholderIssues(track))
        issues.append(contentsOf: promoSpamIssues(track))
        issues.append(contentsOf: filenameDisagreementIssues(track))
        issues.append(contentsOf: embeddedArtistIssues(track))
        issues.append(contentsOf: featuredArtistIssues(track))
        issues.append(contentsOf: yearIssues(track))
        issues.append(contentsOf: genreIssues(track))
        return issues
    }

    public static func summary(for findings: [Finding]) -> String {
        guard !findings.isEmpty else {
            return "No obvious tag problems found."
        }

        var fieldCounts: [Field: Int] = [:]
        for finding in findings {
            for field in finding.affectedFields {
                fieldCounts[field, default: 0] += 1
            }
        }
        let breakdown = fieldCounts
            .sorted { $0.value == $1.value ? $0.key.rawValue < $1.key.rawValue : $0.value > $1.value }
            .map { "\($0.key.displayName) (\($0.value))" }
            .joined(separator: ", ")

        let count = findings.count
        let subject = count == 1 ? "1 track has" : "\(count) tracks have"
        return "\(subject) tag problems: \(breakdown)."
    }

    // MARK: - Individual checks

    private static func missingFieldIssues(_ track: Track) -> [Issue] {
        var issues: [Issue] = []
        if isBlank(track.title) {
            issues.append(Issue(field: .title, severity: .high, summary: "Title is empty."))
        }
        if isBlank(track.artist) {
            issues.append(Issue(field: .artist, severity: .high, summary: "Artist is empty."))
        }
        if isBlank(track.genre) {
            issues.append(Issue(field: .genre, severity: .low, summary: "Genre is empty."))
        }
        if track.year == nil {
            issues.append(Issue(field: .year, severity: .low, summary: "Year is empty."))
        }
        return issues
    }

    /// Values that are technically filled in but carry no information.
    static let placeholderValues: Set<String> = [
        "unknown", "unknown artist", "unknown album", "unknown title",
        "untitled", "no artist", "no album", "various", "various artists",
        "n/a", "na", "none", "null", "-", "--", "?", "??", "track", "audiotrack"
    ]

    private static func placeholderIssues(_ track: Track) -> [Issue] {
        var issues: [Issue] = []
        let candidates: [(Field, String, Severity)] = [
            (.title, track.title, .high),
            (.artist, track.artist, .high),
            (.album, track.album, .medium),
            (.genre, track.genre, .low)
        ]

        for (field, value, severity) in candidates {
            let normalized = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !normalized.isEmpty else { continue }
            if placeholderValues.contains(normalized) {
                issues.append(Issue(
                    field: field,
                    severity: severity,
                    summary: "\(field.displayName) is a placeholder (\"\(value.trimmingCharacters(in: .whitespacesAndNewlines))\")."
                ))
                continue
            }
            // "Track 07", "Audio Track 3", or a bare number: what a ripper
            // writes when it knew nothing about the file.
            if field == .title, isGenericTrackNumberTitle(normalized) {
                issues.append(Issue(
                    field: .title,
                    severity: .high,
                    summary: "Title looks like a rip placeholder (\"\(value.trimmingCharacters(in: .whitespacesAndNewlines))\")."
                ))
            }
        }
        return issues
    }

    static func isGenericTrackNumberTitle(_ normalized: String) -> Bool {
        let patterns = [
            #"^\d{1,3}$"#,
            #"^(audio\s*)?track\s*[-_]?\s*\d{1,3}$"#,
            #"^untitled\s*\d{0,3}$"#
        ]
        return patterns.contains { normalized.range(of: $0, options: .regularExpression) != nil }
    }

    /// Fragments that mean a record pool, rip site, or converter wrote the tag.
    static let promoMarkers: [String] = [
        "www.", "http://", "https://", ".com", ".net", ".org", ".to", ".cc",
        "downloaded from", "free download", "download at", "visit ",
        "bpmsupreme", "bpm supreme", "djcity", "dj city", "digital djpool",
        "zippyshare", "hypeddit", "audiomack", "soundcloud.com", "youtube",
        "yt2", "mp3juice", "320kbps", "kbps", "ripped by", "converted by",
        "@gmail", "telegram", "t.me/"
    ]

    private static func promoSpamIssues(_ track: Track) -> [Issue] {
        var issues: [Issue] = []
        let candidates: [(Field, String, Severity)] = [
            (.title, track.title, .high),
            (.artist, track.artist, .high),
            (.album, track.album, .medium),
            (.comment, track.comment, .low),
            (.genre, track.genre, .medium)
        ]

        for (field, value, severity) in candidates {
            let lowered = value.lowercased()
            guard !lowered.isEmpty else { continue }
            guard let marker = promoMarkers.first(where: { lowered.contains($0) }) else { continue }
            issues.append(Issue(
                field: field,
                severity: severity,
                summary: "\(field.displayName) contains promo/rip text (\"\(marker)\")."
            ))
        }
        return issues
    }

    /// The filename is evidence, not truth — but when a file is named
    /// "Artist - Title" and the tags say something unrelated, one of the two is
    /// wrong and it is worth checking.
    private static func filenameDisagreementIssues(_ track: Track) -> [Issue] {
        guard let parsed = parseArtistTitle(fromFilename: track.fileURL) else { return [] }
        var issues: [Issue] = []

        if !isBlank(track.title), !isBlank(parsed.title),
           !looselyMatches(track.title, parsed.title) {
            issues.append(Issue(
                field: .title,
                severity: .medium,
                summary: "Title \"\(track.title)\" disagrees with the filename (\"\(parsed.title)\")."
            ))
        }

        if !isBlank(track.artist), !isBlank(parsed.artist),
           !looselyMatches(track.artist, parsed.artist) {
            issues.append(Issue(
                field: .artist,
                severity: .medium,
                summary: "Artist \"\(track.artist)\" disagrees with the filename (\"\(parsed.artist)\")."
            ))
        }

        return issues
    }

    /// Splits "Artist - Title.mp3" into its two halves. Returns nil when the
    /// name carries no separator, which is most of the time and is fine.
    static func parseArtistTitle(fromFilename url: URL) -> (artist: String, title: String)? {
        var stem = url.deletingPathExtension().lastPathComponent
        // Strip a leading track number: "03 - Artist - Title" or "03. Title".
        if let range = stem.range(of: #"^\s*\d{1,3}\s*[-._)]\s+"#, options: .regularExpression) {
            stem.removeSubrange(range)
        }

        for separator in [" - ", " – ", " — ", "_-_"] {
            guard let range = stem.range(of: separator) else { continue }
            let artist = String(stem[stem.startIndex..<range.lowerBound])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let title = String(stem[range.upperBound...])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !artist.isEmpty, !title.isEmpty else { continue }
            return (artist, title)
        }
        return nil
    }

    /// A title that still has the artist glued to the front of it — the
    /// signature of a YouTube rip whose video heading became the title.
    private static func embeddedArtistIssues(_ track: Track) -> [Issue] {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty, !isBlank(track.artist) else { return [] }

        let artistPrefix = track.artist.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let loweredTitle = title.lowercased()
        guard loweredTitle.hasPrefix(artistPrefix + " -")
            || loweredTitle.hasPrefix(artistPrefix + " –")
            || loweredTitle.hasPrefix(artistPrefix + ":") else {
            return []
        }

        return [Issue(
            field: .title,
            severity: .medium,
            summary: "Title repeats the artist (\"\(title)\") — it should hold the song name only."
        )]
    }

    /// "feat." belongs in one place consistently. When it appears in the title
    /// but the named guest is nowhere in the artist field (or the reverse),
    /// browsing and searching by artist quietly misses the track.
    private static func featuredArtistIssues(_ track: Track) -> [Issue] {
        guard let featured = featuredArtistName(in: track.title) else { return [] }
        let artist = normalize(track.artist)
        guard !artist.isEmpty, !artist.contains(normalize(featured)) else { return [] }

        return [Issue(
            field: .artist,
            severity: .low,
            summary: "Title credits \"\(featured)\" but the artist field does not mention them."
        )]
    }

    static func featuredArtistName(in title: String) -> String? {
        let pattern = #"(?i)\b(?:feat\.?|featuring|ft\.?|with)\s+([^()\[\]]+)"#
        guard let match = title.range(of: pattern, options: .regularExpression) else { return nil }
        let fragment = String(title[match])
        guard let separator = fragment.range(of: #"(?i)^\s*(?:feat\.?|featuring|ft\.?|with)\s+"#, options: .regularExpression) else {
            return nil
        }
        let name = String(fragment[separator.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    private static func yearIssues(_ track: Track) -> [Issue] {
        guard let year = track.year else { return [] }
        // Recorded music does not predate 1900, and a year beyond next year is
        // a typo or a file timestamp that leaked into the tag.
        let currentYear = Calendar(identifier: .gregorian)
            .component(.year, from: Date())
        guard year < 1900 || year > currentYear + 1 else { return [] }

        return [Issue(
            field: .year,
            severity: .medium,
            summary: "Year \(year) is not a plausible release year."
        )]
    }

    /// Musical keys and BPM values land in the genre field surprisingly often,
    /// usually from a key-detection tool writing to the wrong frame.
    private static func genreIssues(_ track: Track) -> [Issue] {
        let genre = track.genre.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !genre.isEmpty else { return [] }

        let camelotPattern = #"^(?i)\d{1,2}[ab]$"#
        let bpmPattern = #"^\d{2,3}(\.\d+)?$"#
        guard genre.range(of: camelotPattern, options: .regularExpression) != nil
            || genre.range(of: bpmPattern, options: .regularExpression) != nil else {
            return []
        }

        return [Issue(
            field: .genre,
            severity: .medium,
            summary: "Genre \"\(genre)\" looks like a key or BPM value, not a genre."
        )]
    }

    // MARK: - Text helpers

    private static func isBlank(_ value: String) -> Bool {
        value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Comparison form: case-, accent-, and punctuation-insensitive, with
    /// version descriptors dropped. Tag text and filename text are written by
    /// different tools and differ cosmetically far more often than they
    /// genuinely disagree.
    static func normalize(_ value: String) -> String {
        var text = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
        text = text.replacingOccurrences(of: #"\([^()]*\)"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"\[[^\[\]]*\]"#, with: " ", options: .regularExpression)
        text = text.replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
        return text.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
    }

    /// True when two values are the same string once cosmetic differences are
    /// removed, or when one wholly contains the other — a filename routinely
    /// carries extra words the tag omits, and that is not a disagreement.
    static func looselyMatches(_ lhs: String, _ rhs: String) -> Bool {
        let left = normalize(lhs)
        let right = normalize(rhs)
        guard !left.isEmpty, !right.isEmpty else { return true }
        return left == right || left.contains(right) || right.contains(left)
    }
}
