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

/// Trims database results down to what a small on-device model can judge well.
///
/// Measured on Apple's on-device model: handed every result the databases
/// return, it proposed compilation albums ("Clubland 100% Euphoric" for
/// Avicii's "Levels") and remixes EPs for original versions, and the extra
/// lines were part of what overflowed its context window. A larger model
/// weighs those itself; a small one copies whatever looks like an answer. So
/// the obvious wrong answers are removed in code before it sees them, and the
/// most useful ones are put first.
///
/// Kept outside the FoundationModels code so it can be tested on any Mac.
public enum SmallModelEvidence {
    /// How many results the model is shown. Twelve was enough to overflow its
    /// context once a search tool added its own results on top.
    public static let candidateLimit = 6

    /// Album names that are almost always a various-artists or hits
    /// compilation rather than the record a song first appeared on.
    ///
    /// Deliberately a short list of unambiguous markers. Words like "party"
    /// or "classics" also appear in real album titles, and a wrongly dropped
    /// album costs more than a compilation left in.
    static let compilationMarkers = [
        "greatest hits", "best of", "the hits", "hits of", "compilation", "anthology",
        "the collection", "essentials", "now that's what i call", "now thats what i call",
        "clubland", "ministry of sound", "100%", "mixed by", "dj mix", "various artists",
        "top 40", "top 100", "karaoke", "tribute to", "in the style of"
    ]

    public static func isCompilationLike(album: String, artist: String) -> Bool {
        let albumText = album.lowercased()
        if artist.lowercased().contains("various artists") { return true }
        return compilationMarkers.contains { albumText.contains($0) }
    }

    /// A release built around remixes — a remixes EP, or a single named after
    /// one remix ("Midnight City (Eric Prydz Private Remix) - Single") — which
    /// is the right album for a remix and the wrong one for the original the
    /// file is.
    public static func isRemixRelease(album: String, forTitle title: String) -> Bool {
        let albumText = album.lowercased()
        guard albumText.contains("remix") || albumText.contains("rmx") else { return false }
        return !isRemixOrEdit(title)
    }

    /// A single or an EP. Often the only release a dance track has, so kept —
    /// but the album a song appears on is the answer wanted, so these rank
    /// below albums. Measured: given a mix, the model chose "Levels - EP" and
    /// "One More Time - Single" over the albums beside them.
    public static func isSingleOrEP(album: String) -> Bool {
        let text = album.lowercased().trimmingCharacters(in: .whitespaces)
        let markers = [" - single", " - ep", "(single)", "(ep)", " single", " ep"]
        return markers.contains { text.hasSuffix($0) }
    }

    /// The release name without its single or EP suffix, normalised:
    /// "Midnight City - EP" and Deezer's bare "Midnight City" compare equal.
    static func baseName(_ album: String) -> String {
        var text = album.trimmingCharacters(in: .whitespaces)
        for suffix in [" - single", " - ep", "(single)", "(ep)", " single", " ep"]
        where text.lowercased().hasSuffix(suffix) {
            text = String(text.dropLast(suffix.count))
            break
        }
        return TagIntegrityAudit.normalize(text)
    }

    /// An album the evidence agrees a song is on: named by Wikipedia, or by
    /// at least two different databases. One database alone is not enough —
    /// that is how a label sampler or a later re-release gets in.
    ///
    /// Only albums count, and not one named after the song itself, so a
    /// title track ("Thriller" on Thriller) and an EP Wikipedia names as the
    /// song's home never make the song's own release look superseded.
    static func confirmedAlbum(in candidates: [OnlineTrackMetadataCandidate], song: String) -> String? {
        var sourcesByAlbum: [String: Set<OnlineMetadataSource>] = [:]
        var wikipediaAlbum: String?
        for candidate in candidates {
            let key = baseName(candidate.album)
            guard !key.isEmpty, key != song,
                  !isSingleOrEP(album: candidate.album),
                  !isCompilationLike(album: candidate.album, artist: candidate.artist) else { continue }
            sourcesByAlbum[key, default: []].insert(candidate.source)
            if candidate.source == .wikipedia { wikipediaAlbum = key }
        }
        if let wikipediaAlbum { return wikipediaAlbum }
        return sourcesByAlbum.first { $0.value.count >= 2 }?.key
    }

    /// True for a single or EP that only packaged the song ahead of an
    /// album — safe to hide, because the album is the answer and a small
    /// model shown both picks the EP anyway (measured: "Midnight City - EP"
    /// over "Hurry Up, We're Dreaming", even ranked below it).
    ///
    /// Real EPs must survive, so all three must hold:
    /// 1. it is named after the song ("Midnight City - EP", or Deezer's bare
    ///    "Feel So Close"). An EP with its own name is a release in its own
    ///    right and is never hidden;
    /// 2. a confirmed album exists (see `confirmedAlbum`);
    /// 3. it is not what the file is already tagged with — hiding that would
    ///    make the user's own value look unsupported.
    static func isLeadSingleRelease(
        album: String,
        song: String,
        confirmedAlbum: String?,
        fileAlbum: String
    ) -> Bool {
        guard confirmedAlbum != nil, baseName(album) == song else { return false }
        return TagIntegrityAudit.normalize(album) != TagIntegrityAudit.normalize(fileAlbum)
    }

    /// True for a remix, edit, or bootleg. "Original Mix" is the original.
    static func isRemixOrEdit(_ title: String) -> Bool {
        let text = title.lowercased()
        return ["remix", "rmx", "bootleg", "edit", "rework", "flip", "vip"].contains { text.contains($0) }
    }

    /// The results to show the model, best first, at most `limit`.
    ///
    /// Compilations and remix releases are dropped, but only while something
    /// else is left: a track that only ever appeared on a compilation still
    /// needs its album. Lead singles and EPs are dropped only when a
    /// confirmed album replaces them (see `isLeadSingleRelease`). Wikipedia comes first because it names the original
    /// album most reliably; then albums ahead of singles and EPs; then results
    /// whose length is closest to the file's, since a result minutes off is a
    /// different version.
    public static func curated(
        _ candidates: [OnlineTrackMetadataCandidate],
        fileTitle: String,
        fileDuration: Double?,
        fileAlbum: String = "",
        limit: Int = candidateLimit
    ) -> [OnlineTrackMetadataCandidate] {
        let song = baseName(OnlineTrackMetadataLookupService.searchableTerm(fileTitle))
        let album = confirmedAlbum(in: candidates, song: song)
        let kept = candidates.filter { candidate in
            !isCompilationLike(album: candidate.album, artist: candidate.artist)
                && !isRemixRelease(album: candidate.album, forTitle: fileTitle)
                && !isLeadSingleRelease(album: candidate.album, song: song, confirmedAlbum: album, fileAlbum: fileAlbum)
        }
        let pool = kept.isEmpty ? candidates : kept

        func lengthGap(_ candidate: OnlineTrackMetadataCandidate) -> Double {
            guard let fileDuration, fileDuration > 0,
                  let duration = candidate.durationSeconds, duration > 0 else {
                return .greatestFiniteMagnitude
            }
            return abs(duration - fileDuration)
        }

        return pool.enumerated()
            .sorted { lhs, rhs in
                let lhsWiki = lhs.element.source == .wikipedia
                let rhsWiki = rhs.element.source == .wikipedia
                if lhsWiki != rhsWiki { return lhsWiki }
                let lhsSingle = isSingleOrEP(album: lhs.element.album)
                let rhsSingle = isSingleOrEP(album: rhs.element.album)
                if lhsSingle != rhsSingle { return rhsSingle }
                let lhsGap = lengthGap(lhs.element)
                let rhsGap = lengthGap(rhs.element)
                if lhsGap != rhsGap { return lhsGap < rhsGap }
                return lhs.offset < rhs.offset
            }
            .prefix(limit)
            .map(\.element)
    }
}
