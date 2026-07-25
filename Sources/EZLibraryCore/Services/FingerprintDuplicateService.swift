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

/// What fingerprinting concluded about a metadata-matched duplicate group.
public enum FingerprintStatus: Sendable, Equatable {
    /// Every track was fingerprinted and they are the same recording.
    case audioConfirmed

    /// Fingerprinting split a larger metadata group; this is one piece of it.
    /// The tracks here are the same recording as each other.
    case audioConfirmedSubset(originalTrackCount: Int)

    /// Found by a whole-library audio scan, and the tracks' tags disagree —
    /// metadata matching could never have grouped these.
    case audioOnlyMatch

    /// Could not verify — reported as a metadata match only, never silently
    /// upgraded to "confirmed".
    case unverified(reason: String)

    public var isConfirmed: Bool {
        switch self {
        case .audioConfirmed, .audioConfirmedSubset, .audioOnlyMatch:
            return true
        case .unverified:
            return false
        }
    }

    /// Short label for the duplicates UI.
    public var badgeText: String {
        switch self {
        case .audioConfirmed:
            return "Audio verified"
        case .audioConfirmedSubset:
            return "Audio verified (split)"
        case .audioOnlyMatch:
            return "Audio match · tags differ"
        case .unverified:
            return "Tags only"
        }
    }
}

public struct VerifiedDuplicateGroup: Identifiable, Sendable {
    public let group: DuplicateTrackGroup
    public let status: FingerprintStatus

    /// Other versions of this same recording that exist in the library —
    /// "Intro", "Quick Hit", "Acapella".
    ///
    /// Present so the UI can say out loud that deleting here won't touch those
    /// versions, and so a DJ can see the version set they own at a glance.
    public let relatedVersions: [String]

    /// Copies here are close but not bit-identical, so they are shown but not
    /// pre-selected for deletion.
    public let needsListenBeforeDeleting: Bool

    public var id: String { group.id }

    public init(
        group: DuplicateTrackGroup,
        status: FingerprintStatus,
        relatedVersions: [String] = [],
        needsListenBeforeDeleting: Bool = false
    ) {
        self.group = group
        self.status = status
        self.relatedVersions = relatedVersions
        self.needsListenBeforeDeleting = needsListenBeforeDeleting
    }
}

public struct FingerprintVerificationResult: Sendable {
    public let groups: [VerifiedDuplicateGroup]
    public let cache: AudioFingerprintCache
    /// Tracks the metadata pass grouped that audio proved distinct. These are
    /// no longer offered for deletion.
    public let falsePositiveTrackCount: Int
    public let fingerprintedFileCount: Int
    public let failures: [URL: AudioFingerprintExtractor.ExtractionError]
}

/// Verifies metadata duplicate groups against the actual audio.
///
/// The expensive stage is extraction, so this gates hard before reaching it:
/// only tracks already in a metadata group are considered, and within a group
/// tracks whose durations can't possibly align are separated for free.
public enum FingerprintDuplicateService {
    /// How far two durations may differ and still be the same recording.
    ///
    /// Encoder padding and a trimmed lead-in move the reported length by a
    /// second or two; the matcher's alignment search only absorbs ~7.4s, so
    /// anything beyond this could not match even if fingerprinted.
    public static let durationToleranceSeconds: TimeInterval = 5

    public static func verify(
        groups: [DuplicateTrackGroup],
        cache: AudioFingerprintCache = .load(),
        analysisSeconds: Int = AudioFingerprintExtractor.defaultAnalysisSeconds,
        threshold: Double = AudioFingerprintMatcher.defaultMatchThreshold,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> FingerprintVerificationResult {
        guard !groups.isEmpty else {
            return FingerprintVerificationResult(
                groups: [],
                cache: cache,
                falsePositiveTrackCount: 0,
                fingerprintedFileCount: 0,
                failures: [:]
            )
        }

        guard AudioFingerprintService.fpcalcExecutablePath() != nil else {
            // Degrade to the metadata result rather than failing the scan —
            // the user still gets their duplicates, just unverified.
            let reason = AudioFingerprintExtractor.ExtractionError
                .fpcalcNotInstalled.localizedDescription
            return FingerprintVerificationResult(
                groups: groups.map { VerifiedDuplicateGroup(group: $0, status: .unverified(reason: reason)) },
                cache: cache,
                falsePositiveTrackCount: 0,
                fingerprintedFileCount: 0,
                failures: [:]
            )
        }

        // Free pass: split each group by duration before spending any decode time.
        let bucketedGroups = groups.map { (group: $0, buckets: durationBuckets(for: $0.tracks)) }

        // Only buckets that still hold more than one track need fingerprints.
        var needed: [URL] = []
        for entry in bucketedGroups {
            for bucket in entry.buckets where bucket.count > 1 {
                needed.append(contentsOf: bucket.map(\.fileURL))
            }
        }
        let uniqueNeeded = Array(Set(needed))

        let (cached, missing) = cache.partition(uniqueNeeded, analysisSeconds: analysisSeconds)

        var extracted: [URL: AudioFingerprint] = [:]
        var failures: [URL: AudioFingerprintExtractor.ExtractionError] = [:]
        if !missing.isEmpty {
            let outcome = try await AudioFingerprintExtractor.extractMany(
                fileURLs: missing,
                analysisSeconds: analysisSeconds,
                progress: progress
            )
            extracted = outcome.fingerprints
            failures = outcome.failures
        }

        var updatedCache = cache
        updatedCache.store(extracted, analysisSeconds: analysisSeconds)

        var fingerprints = cached
        fingerprints.merge(extracted) { current, _ in current }

        var verified: [VerifiedDuplicateGroup] = []
        var falsePositiveTracks = 0

        for entry in bucketedGroups {
            let originalCount = entry.group.tracks.count
            var producedTracks = 0

            for bucket in entry.buckets {
                guard bucket.count > 1 else {
                    continue
                }

                // A bucket only verifies if every member has a fingerprint;
                // otherwise report it as a tag-only match rather than guessing.
                let items: [(key: String, fingerprint: AudioFingerprint)] = bucket.compactMap { track in
                    guard let fingerprint = fingerprints[track.fileURL] else { return nil }
                    return (key: track.seratoStoredPath, fingerprint: fingerprint)
                }

                guard items.count == bucket.count else {
                    let reason = unverifiedReason(for: bucket, fingerprints: fingerprints, failures: failures)
                    verified.append(
                        VerifiedDuplicateGroup(
                            group: rebuild(entry.group, with: bucket, suffix: nil),
                            status: .unverified(reason: reason)
                        )
                    )
                    producedTracks += bucket.count
                    continue
                }

                let byPath = Dictionary(uniqueKeysWithValues: bucket.map { ($0.seratoStoredPath, $0) })
                let clusters = AudioFingerprintMatcher.cluster(items, threshold: threshold)

                for (index, cluster) in clusters.enumerated() {
                    let tracks = cluster.compactMap { byPath[$0] }
                    guard tracks.count > 1 else { continue }

                    // Only tag the result as a subset when the audio genuinely
                    // carved the original group up.
                    let isSubset = tracks.count < originalCount
                    let status: FingerprintStatus = isSubset
                        ? .audioConfirmedSubset(originalTrackCount: originalCount)
                        : .audioConfirmed

                    verified.append(
                        VerifiedDuplicateGroup(
                            group: rebuild(
                                entry.group,
                                with: tracks,
                                suffix: clusters.count > 1 ? "audio\(index + 1)" : nil
                            ),
                            status: status
                        )
                    )
                    producedTracks += tracks.count
                }
            }

            falsePositiveTracks += max(0, originalCount - producedTracks)
        }

        return FingerprintVerificationResult(
            groups: verified.sorted { lhs, rhs in
                if lhs.group.redundantTrackCount != rhs.group.redundantTrackCount {
                    return lhs.group.redundantTrackCount > rhs.group.redundantTrackCount
                }
                return lhs.group.id.localizedStandardCompare(rhs.group.id) == .orderedAscending
            },
            cache: updatedCache,
            falsePositiveTrackCount: falsePositiveTracks,
            fingerprintedFileCount: extracted.count + cached.count,
            failures: failures
        )
    }

    /// Groups tracks whose durations are close enough to be the same recording.
    ///
    /// Returns a single bucket when any duration is unknown — the gate is an
    /// optimization, and it must never split a real duplicate pair just because
    /// Serato had no duration for one of them.
    static func durationBuckets(
        for tracks: [Track],
        tolerance: TimeInterval = durationToleranceSeconds
    ) -> [[Track]] {
        guard tracks.count > 1 else { return tracks.isEmpty ? [] : [tracks] }
        guard tracks.allSatisfy({ ($0.duration ?? 0) > 0 }) else { return [tracks] }

        let sorted = tracks.sorted { ($0.duration ?? 0) < ($1.duration ?? 0) }
        var buckets: [[Track]] = []
        var current: [Track] = [sorted[0]]

        for track in sorted.dropFirst() {
            // Compare against the previous track rather than the bucket's first,
            // so a run of gradually increasing durations stays together.
            let previous = current[current.count - 1].duration ?? 0
            if abs((track.duration ?? 0) - previous) <= tolerance {
                current.append(track)
            } else {
                buckets.append(current)
                current = [track]
            }
        }
        buckets.append(current)
        return buckets
    }

    private static func unverifiedReason(
        for tracks: [Track],
        fingerprints: [URL: AudioFingerprint],
        failures: [URL: AudioFingerprintExtractor.ExtractionError]
    ) -> String {
        let unresolved = tracks.filter { fingerprints[$0.fileURL] == nil }
        if let first = unresolved.first, let failure = failures[first.fileURL] {
            return failure.localizedDescription
        }
        if let first = unresolved.first {
            return "Could not fingerprint \(first.fileURL.lastPathComponent)."
        }
        return "Could not fingerprint every track in this group."
    }

    /// Rebuilds a group around a subset of its tracks, keeping the original
    /// display fields. `suffix` keeps split groups' IDs distinct so the
    /// ignore-store and SwiftUI identity don't collide.
    private static func rebuild(
        _ group: DuplicateTrackGroup,
        with tracks: [Track],
        suffix: String?
    ) -> DuplicateTrackGroup {
        DuplicateTrackGroup(
            id: suffix.map { "\(group.id)|\($0)" } ?? group.id,
            artist: group.artist,
            title: group.title,
            versionLabel: group.versionLabel,
            tracks: tracks
        )
    }
}
