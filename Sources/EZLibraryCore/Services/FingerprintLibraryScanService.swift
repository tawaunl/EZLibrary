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

public struct LibraryFingerprintScanResult: Sendable {
    public let groups: [VerifiedDuplicateGroup]
    public let cache: AudioFingerprintCache
    /// Tracks that were successfully fingerprinted.
    public let scannedTrackCount: Int
    /// Groups whose tracks disagree on artist/title — the duplicates that
    /// metadata matching could never have found.
    public let tagMismatchGroupCount: Int
    public let failures: [URL: AudioFingerprintExtractor.ExtractionError]
}

/// Finds duplicates across the whole library from audio alone, ignoring tags.
///
/// This is the counterpart to `FingerprintDuplicateService`, which can only
/// narrow groups that metadata already formed. When tags are wrong, missing, or
/// inconsistent, those copies never land in the same metadata group, so nothing
/// downstream ever compares them. This scan starts from the audio instead.
///
/// It costs a full-library decode on the first run (~15 min for 50k tracks at
/// measured throughput), so it is explicitly user-triggered, reports progress,
/// is cancellable, and persists fingerprints as it goes.
public enum FingerprintLibraryScanService {
    public enum ScanPhase: Sendable, Equatable {
        /// Decoding audio — the long stage.
        case fingerprinting
        /// Indexing and comparing — seconds, even on a large library.
        case matching
    }

    /// Files fingerprinted between cache writes.
    ///
    /// A full scan can run for many minutes, so progress is checkpointed:
    /// cancelling or quitting costs at most this much redundant work rather
    /// than the whole run.
    private static let checkpointInterval = 500

    public static func scan(
        tracks: [Track],
        cache: AudioFingerprintCache = .load(),
        analysisSeconds: Int = AudioFingerprintExtractor.defaultAnalysisSeconds,
        threshold: Double = AudioFingerprintMatcher.defaultMatchThreshold,
        cacheURL: URL? = AudioFingerprintCache.defaultURL(),
        /// Drop cached fingerprints for files outside `tracks`.
        ///
        /// Off by default, and only safe when `tracks` really is the whole
        /// library: pruning on a subset throws away everything else's
        /// fingerprints and makes the next full scan pay for a cold decode
        /// again.
        pruneCacheToTracks: Bool = false,
        progress: (@Sendable (ScanPhase, Int, Int) -> Void)? = nil
    ) async throws -> LibraryFingerprintScanResult {
        // One entry per file: a library can reference the same file twice, and
        // fingerprinting it twice would waste the expensive stage.
        var trackByPath: [String: Track] = [:]
        for track in tracks where !track.isMissing {
            trackByPath[track.fileURL.path] = track
        }
        let candidates = Array(trackByPath.values)

        guard candidates.count > 1 else {
            return LibraryFingerprintScanResult(
                groups: [],
                cache: cache,
                scannedTrackCount: 0,
                tagMismatchGroupCount: 0,
                failures: [:]
            )
        }

        guard AudioFingerprintService.fpcalcExecutablePath() != nil else {
            throw AudioFingerprintExtractor.ExtractionError.fpcalcNotInstalled
        }

        var workingCache = cache
        var fingerprints: [URL: AudioFingerprint] = [:]
        var failures: [URL: AudioFingerprintExtractor.ExtractionError] = [:]

        let urls = candidates.map(\.fileURL)
        let (cached, missing) = workingCache.partition(urls, analysisSeconds: analysisSeconds)
        fingerprints = cached

        let total = urls.count
        progress?(.fingerprinting, cached.count, total)

        // Extract in checkpointed batches so a long scan can be interrupted
        // without discarding everything decoded so far.
        var batchStart = 0
        while batchStart < missing.count {
            if Task.isCancelled {
                try? workingCache.save(to: cacheURL)
                throw CancellationError()
            }

            let batchEnd = min(batchStart + checkpointInterval, missing.count)
            let batch = Array(missing[batchStart..<batchEnd])
            let alreadyDone = cached.count + batchStart

            do {
                let outcome = try await AudioFingerprintExtractor.extractMany(
                    fileURLs: batch,
                    analysisSeconds: analysisSeconds,
                    progress: { completed, _ in
                        progress?(.fingerprinting, alreadyDone + completed, total)
                    }
                )
                fingerprints.merge(outcome.fingerprints) { current, _ in current }
                failures.merge(outcome.failures) { current, _ in current }
                workingCache.store(outcome.fingerprints, analysisSeconds: analysisSeconds)
            } catch is CancellationError {
                try? workingCache.save(to: cacheURL)
                throw CancellationError()
            }

            try? workingCache.save(to: cacheURL)
            batchStart = batchEnd
        }

        progress?(.matching, 0, 0)
        try Task.checkCancellation()

        // Only tracks with a fingerprint can participate.
        let scannable = candidates.compactMap { track -> (track: Track, fingerprint: AudioFingerprint)? in
            guard let fingerprint = fingerprints[track.fileURL] else { return nil }
            return (track, fingerprint)
        }

        let groups = matchGroups(from: scannable, threshold: threshold)

        if pruneCacheToTracks {
            workingCache.prune(keeping: Set(urls.map(\.path)))
        }
        try? workingCache.save(to: cacheURL)

        return LibraryFingerprintScanResult(
            groups: groups,
            cache: workingCache,
            scannedTrackCount: scannable.count,
            tagMismatchGroupCount: groups.filter { $0.status == .audioOnlyMatch }.count,
            failures: failures
        )
    }

    /// Builds duplicate groups from fingerprints, via signature candidates then
    /// full comparison.
    static func matchGroups(
        from scannable: [(track: Track, fingerprint: AudioFingerprint)],
        threshold: Double = AudioFingerprintMatcher.defaultMatchThreshold
    ) -> [VerifiedDuplicateGroup] {
        guard scannable.count > 1 else { return [] }

        let signatures = scannable.map { AudioFingerprintIndex.signature(for: $0.fingerprint) }
        let pairs = AudioFingerprintIndex.candidatePairs(signatures: signatures)
        guard !pairs.isEmpty else { return [] }

        // Union-find over confirmed pairs, so a chain of matches becomes one
        // group — matching `AudioFingerprintMatcher.cluster`'s behavior.
        var parent = Array(0..<scannable.count)
        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            var current = index
            while parent[current] != current {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }

        for (left, right) in pairs {
            guard find(left) != find(right) else { continue }
            if AudioFingerprintMatcher.isMatch(
                scannable[left].fingerprint,
                scannable[right].fingerprint,
                threshold: threshold
            ) {
                parent[find(left)] = find(right)
            }
        }

        var members: [Int: [Int]] = [:]
        for index in 0..<scannable.count {
            let root = find(index)
            // Only tracks that actually matched something form a group.
            if root != index || members[root] != nil {
                members[root, default: []].append(index)
            }
        }

        var groups: [VerifiedDuplicateGroup] = []
        for (_, indices) in members where indices.count > 1 {
            let tracks = indices.map { scannable[$0].track }
                .sorted { $0.seratoStoredPath.localizedStandardCompare($1.seratoStoredPath) == .orderedAscending }
            groups.append(makeGroup(from: tracks))
        }

        return groups.sorted { lhs, rhs in
            if lhs.group.redundantTrackCount != rhs.group.redundantTrackCount {
                return lhs.group.redundantTrackCount > rhs.group.redundantTrackCount
            }
            return lhs.group.id.localizedStandardCompare(rhs.group.id) == .orderedAscending
        }
    }

    private static func makeGroup(from tracks: [Track]) -> VerifiedDuplicateGroup {
        let best = DuplicateTracksService.bestTrack(in: tracks) ?? tracks[0]
        let title = best.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = best.artist.trimmingCharacters(in: .whitespacesAndNewlines)

        let group = DuplicateTrackGroup(
            // Derived from membership so the ID is stable across rescans.
            id: "audio|" + (tracks.first?.seratoStoredPath ?? UUID().uuidString),
            artist: artist.isEmpty ? "Unknown Artist" : artist,
            title: title.isEmpty ? best.fileURL.deletingPathExtension().lastPathComponent : title,
            versionLabel: DuplicateTracksService.versionLabel(for: best),
            tracks: tracks
        )

        return VerifiedDuplicateGroup(
            group: group,
            status: tagsAgree(across: tracks) ? .audioConfirmed : .audioOnlyMatch
        )
    }

    /// Whether metadata matching would already have grouped these tracks.
    ///
    /// Reuses the real grouping rules rather than comparing strings, so
    /// "tags differ" means exactly "the ID3 pass would have missed this".
    private static func tagsAgree(across tracks: [Track]) -> Bool {
        let metadataGroups = DuplicateTracksService.duplicateGroups(in: tracks)
        return metadataGroups.count == 1 && metadataGroups[0].tracks.count == tracks.count
    }
}
