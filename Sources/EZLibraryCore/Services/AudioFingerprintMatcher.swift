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

/// A raw Chromaprint fingerprint: one 32-bit sub-fingerprint per frame, where
/// each frame covers ~0.1238s of audio.
///
/// Raw (rather than AcoustID's compressed base64) is what makes offline
/// duplicate detection possible — the individual bits are comparable, so two
/// files can be matched against each other without any network call or API key.
public struct AudioFingerprint: Sendable, Hashable {
    /// Seconds of audio in the source file, as reported by fpcalc.
    public let duration: Int
    /// Sub-fingerprints, in frame order.
    public let hashes: [UInt32]

    public init(duration: Int, hashes: [UInt32]) {
        self.duration = duration
        self.hashes = hashes
    }

    /// Seconds of audio each sub-fingerprint frame represents.
    public static let secondsPerFrame = 0.1238

    public var isEmpty: Bool { hashes.isEmpty }
}

/// Compares raw Chromaprint fingerprints to decide whether two files are the
/// same recording.
///
/// Matching is intentionally offline and allocation-free in the inner loop:
/// a 50k-track library only ever reaches this code for pairs that already
/// survived metadata and duration gating, but those pairs still need to be
/// cheap enough to run in bulk.
public enum AudioFingerprintMatcher {
    /// Score at or above which two fingerprints are treated as the same
    /// recording. Identical audio in different encodings typically scores well
    /// above 0.9; genuinely different tracks sit near 0.5 (random bits agree
    /// half the time), so 0.85 leaves a wide margin on both sides.
    public static let defaultMatchThreshold = 0.85

    /// How far the alignment search shifts one fingerprint against the other,
    /// in frames. Different rips of the same track often differ by a short
    /// silent lead-in; ±60 frames covers about ±7.4s of drift.
    public static let defaultMaxOffsetFrames = 60

    /// Frames that must overlap before a score is considered meaningful.
    /// Without a floor, a 2-frame overlap that happens to agree would score
    /// 1.0. 80 frames is roughly 10s of audio.
    public static let minimumOverlapFrames = 80

    /// Below this many frames (~5s) a fingerprint is not judged at all.
    ///
    /// Short fingerprints are genuinely dangerous here: a handful of frames
    /// with similar bit patterns can score above the threshold by coincidence
    /// (five small integers vs five copies of `9` scores 0.93), and this
    /// feature's output leads to deleting files. Refusing to judge is the safe
    /// answer — such a file simply won't be reported as a duplicate.
    public static let minimumComparableFrames = 40

    /// Best similarity between two fingerprints across the alignment search,
    /// in `0...1` where 1.0 means bit-identical.
    ///
    /// Returns 0 when neither alignment produces enough overlapping frames to
    /// judge, so callers can treat "too short to compare" as "not a match".
    public static func similarity(
        _ lhs: AudioFingerprint,
        _ rhs: AudioFingerprint,
        maxOffsetFrames: Int = defaultMaxOffsetFrames
    ) -> Double {
        let a = lhs.hashes
        let b = rhs.hashes
        let shorter = min(a.count, b.count)
        // Too little audio to distinguish a real match from a coincidence.
        guard shorter >= minimumComparableFrames else { return 0 }

        // An overlap can never exceed the shorter fingerprint, so allow the
        // floor to fall back to it for files between the two limits.
        let overlapFloor = min(minimumOverlapFrames, shorter)
        var best = 0.0

        for offset in -maxOffsetFrames...maxOffsetFrames {
            // `offset` shifts `b` relative to `a`.
            let start = max(0, offset)
            let end = min(a.count, b.count + offset)
            let overlap = end - start
            guard overlap >= overlapFloor, overlap > 0 else { continue }

            var differingBits = 0
            for i in start..<end {
                differingBits += (a[i] ^ b[i - offset]).nonzeroBitCount
            }

            let score = 1.0 - (Double(differingBits) / Double(overlap * 32))
            if score > best {
                best = score
                // Bit-identical: no later offset can beat this.
                if best >= 1.0 { break }
            }
        }

        return best
    }

    /// Whether two fingerprints represent the same recording.
    public static func isMatch(
        _ lhs: AudioFingerprint,
        _ rhs: AudioFingerprint,
        threshold: Double = defaultMatchThreshold,
        maxOffsetFrames: Int = defaultMaxOffsetFrames
    ) -> Bool {
        similarity(lhs, rhs, maxOffsetFrames: maxOffsetFrames) >= threshold
    }

    /// Partitions `items` into clusters of the same recording.
    ///
    /// Clustering is single-linkage via union-find: A and C land together when
    /// both match B, which is the behavior duplicate review wants (one card per
    /// recording) even when the weakest pair sits just under the threshold.
    ///
    /// This is O(n²) in the size of the *group*, not the library. Callers gate
    /// with metadata and duration first so `items` stays small.
    public static func cluster<Key: Hashable>(
        _ items: [(key: Key, fingerprint: AudioFingerprint)],
        threshold: Double = defaultMatchThreshold,
        maxOffsetFrames: Int = defaultMaxOffsetFrames
    ) -> [[Key]] {
        guard items.count > 1 else {
            return items.isEmpty ? [] : [[items[0].key]]
        }

        var parent = Array(0..<items.count)

        func find(_ index: Int) -> Int {
            var root = index
            while parent[root] != root { root = parent[root] }
            // Path compression keeps repeated lookups flat.
            var current = index
            while parent[current] != current {
                let next = parent[current]
                parent[current] = root
                current = next
            }
            return root
        }

        for i in 0..<items.count {
            for j in (i + 1)..<items.count {
                guard find(i) != find(j) else { continue }
                if isMatch(
                    items[i].fingerprint,
                    items[j].fingerprint,
                    threshold: threshold,
                    maxOffsetFrames: maxOffsetFrames
                ) {
                    parent[find(i)] = find(j)
                }
            }
        }

        var clusters: [Int: [Key]] = [:]
        for (index, item) in items.enumerated() {
            clusters[find(index), default: []].append(item.key)
        }

        // Preserve input order so results are deterministic.
        var seen = Set<Int>()
        var ordered: [[Key]] = []
        for index in 0..<items.count {
            let root = find(index)
            if seen.insert(root).inserted, let cluster = clusters[root] {
                ordered.append(cluster)
            }
        }
        return ordered
    }
}
