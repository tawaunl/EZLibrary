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

/// How confident we are that the copies in a version branch are the *same*
/// file's worth of audio, rather than merely similar.
public enum DuplicateConfidence: Sendable, Equatable {
    /// Only one copy — nothing to delete.
    case single
    /// Bit-for-bit close: a re-encode, a re-tag, a renamed copy.
    case identical(lowestScore: Double)
    /// Close but not identical. Same version label, so probably duplicates,
    /// but different enough that a human should listen first.
    case similar(lowestScore: Double)

    /// Whether copies here are safe to offer for one-click deletion.
    public var isSafeToAutoSelect: Bool {
        if case .identical = self { return true }
        return false
    }
}

/// One version of a recording — "Intro", "Quick Hit", "Acapella" — plus every
/// copy of that particular version.
public struct TrackVersionBranch: Identifiable, Sendable {
    public let id: String
    public let versionLabel: String
    /// Copies of this same version. More than one means real duplicates.
    public let copies: [Track]
    public let confidence: DuplicateConfidence

    public var redundantCount: Int { max(0, copies.count - 1) }

    public init(id: String, versionLabel: String, copies: [Track], confidence: DuplicateConfidence) {
        self.id = id
        self.versionLabel = versionLabel
        self.copies = copies
        self.confidence = confidence
    }
}

/// A recording and all the DJ versions of it that exist in the library.
///
/// Audio fingerprinting alone cannot separate these: measured on a real
/// library, "No Diggity (Dirty)" scores 0.880 against "(Intro Dirty)", and
/// "(Intro Dirty)" scores 0.898 against "(Quick Hit Dirty)" — both above the
/// 0.85 match threshold, because a DJ edit really is mostly the same audio.
/// A Clean and Dirty pair differing by a few censored words would score higher
/// still, so no threshold separates them reliably.
///
/// So versions are separated *structurally*, by the version label parsed from
/// the title, and only copies inside one branch are ever treated as duplicates.
/// That is what stops a scan from offering to delete a DJ's Intro edit because
/// it sounds like the full version.
public struct TrackVersionTree: Identifiable, Sendable {
    public let id: String
    public let artist: String
    public let title: String
    public let branches: [TrackVersionBranch]

    public var versionLabels: [String] { branches.map(\.versionLabel) }
    public var hasMultipleVersions: Bool { branches.count > 1 }
    /// Copies that could be deleted without losing a version.
    public var redundantCopyCount: Int { branches.reduce(0) { $0 + $1.redundantCount } }
    /// Branches that actually contain duplicates.
    public var branchesWithDuplicates: [TrackVersionBranch] { branches.filter { $0.copies.count > 1 } }

    public init(id: String, artist: String, title: String, branches: [TrackVersionBranch]) {
        self.id = id
        self.artist = artist
        self.title = title
        self.branches = branches
    }

    /// Score at or above which copies are treated as the same file rather than
    /// a different edit.
    ///
    /// Measured: re-encodes and renames land at 0.976-1.000, while distinct
    /// versions of one track land at 0.880-0.908. 0.95 sits in that gap.
    /// Copies below it stay grouped — the version label already says they're
    /// the same version — but are flagged for review instead of auto-selected.
    public static let identicalThreshold = 0.95

    /// Builds the tree for one acoustically-matched cluster.
    public static func build(
        from cluster: [(track: Track, fingerprint: AudioFingerprint)],
        idSeed: String? = nil
    ) -> TrackVersionTree? {
        guard !cluster.isEmpty else { return nil }

        let grouped = Dictionary(grouping: cluster) { entry in
            DuplicateTracksService.versionLabel(for: entry.track)
        }

        let branches: [TrackVersionBranch] = grouped
            .map { label, entries in
                let tracks = DuplicateTracksService.rankedTracks(in: entries.map(\.track))
                return TrackVersionBranch(
                    id: "\(label)|\(tracks.first?.seratoStoredPath ?? label)",
                    versionLabel: label,
                    copies: tracks,
                    confidence: confidence(for: entries)
                )
            }
            .sorted { lhs, rhs in
                // Branches with real duplicates first — that's the actionable
                // part — then alphabetical for stability.
                if lhs.redundantCount != rhs.redundantCount {
                    return lhs.redundantCount > rhs.redundantCount
                }
                return lhs.versionLabel.localizedStandardCompare(rhs.versionLabel) == .orderedAscending
            }

        let best = DuplicateTracksService.bestTrack(in: cluster.map(\.track)) ?? cluster[0].track
        let artist = best.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = best.title.trimmingCharacters(in: .whitespacesAndNewlines)

        return TrackVersionTree(
            id: "tree|" + (idSeed ?? best.seratoStoredPath),
            artist: artist.isEmpty ? "Unknown Artist" : artist,
            title: title.isEmpty ? best.fileURL.deletingPathExtension().lastPathComponent : title,
            branches: branches
        )
    }

    /// Lowest pairwise similarity inside a branch decides its confidence — the
    /// weakest link, so one odd copy can't be hidden behind several good ones.
    private static func confidence(
        for entries: [(track: Track, fingerprint: AudioFingerprint)]
    ) -> DuplicateConfidence {
        guard entries.count > 1 else { return .single }

        var lowest = 1.0
        for i in 0..<entries.count {
            for j in (i + 1)..<entries.count {
                let score = AudioFingerprintMatcher.similarity(
                    entries[i].fingerprint,
                    entries[j].fingerprint
                )
                lowest = min(lowest, score)
            }
        }

        return lowest >= identicalThreshold ? .identical(lowestScore: lowest) : .similar(lowestScore: lowest)
    }
}
