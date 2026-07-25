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

/// Finds which tracks are worth comparing, without comparing every pair.
///
/// A whole-library acoustic scan can't test every pair — 50k tracks is 1.25
/// billion of them, and each full comparison costs ~115k operations. This
/// narrows the field first: every track gets a small MinHash signature, and
/// only tracks sharing several signature values are compared properly.
///
/// Measured on 400 real library tracks: 79,800 possible pairs reduced to 137
/// candidates (a 582x cut) with no true duplicate lost.
public enum AudioFingerprintIndex {
    /// Values kept per track. 64 of ~948 frames is enough to be distinctive
    /// while keeping the whole index small (50k tracks ≈ 12 MB).
    public static let defaultSignatureSize = 64

    /// Shared values before two tracks are worth a full comparison.
    ///
    /// Re-encodes share 48-51 of 64 and a shifted copy still shares 34, while
    /// unrelated tracks share 0 — random collisions are vanishingly rare
    /// (~64²/2³² per pair). Four is far below every true match and far above
    /// the noise.
    public static let defaultMinSharedValues = 4

    /// Signature values held by more tracks than this are ignored.
    ///
    /// A value common to hundreds of tracks (digital silence, a shared drop-in)
    /// says nothing about any particular pair, and pairing up a huge posting
    /// list would swamp candidate generation.
    public static let defaultMaxPostingsPerValue = 100

    /// A track's signature: the `size` smallest mixed sub-fingerprints.
    ///
    /// Chosen by value rather than position so it survives a time shift — a
    /// trimmed or padded lead-in renumbers every frame, but barely changes the
    /// *set* of values. Values are mixed through a 32-bit finalizer first so
    /// selection isn't biased toward degenerate low sub-fingerprints, which
    /// tend to mean silence and would be common to unrelated tracks.
    public static func signature(
        for fingerprint: AudioFingerprint,
        size: Int = defaultSignatureSize
    ) -> [UInt32] {
        guard !fingerprint.hashes.isEmpty else { return [] }

        var mixed = Set<UInt32>(minimumCapacity: fingerprint.hashes.count)
        for hash in fingerprint.hashes {
            mixed.insert(mix(hash))
        }

        return Array(mixed.sorted().prefix(size))
    }

    /// A 32-bit finalizer with good avalanche, so nearby inputs scatter.
    private static func mix(_ value: UInt32) -> UInt32 {
        var x = value
        x ^= x >> 16
        x = x &* 0x7feb_352d
        x ^= x >> 15
        x = x &* 0x846c_a68b
        x ^= x >> 16
        return x
    }

    /// Index positions of track pairs sharing at least `minShared` signature
    /// values. Pairs are returned with the lower index first.
    public static func candidatePairs(
        signatures: [[UInt32]],
        minShared: Int = defaultMinSharedValues,
        maxPostingsPerValue: Int = defaultMaxPostingsPerValue
    ) -> [(Int, Int)] {
        guard signatures.count > 1 else { return [] }

        // Inverted index as a sorted (value, track) array rather than a
        // dictionary of arrays: 50k tracks is ~3.2M postings, and a flat
        // buffer keeps that ~25 MB and cache-friendly instead of millions of
        // separately allocated arrays.
        var postings: [(value: UInt32, track: Int32)] = []
        postings.reserveCapacity(signatures.reduce(0) { $0 + $1.count })
        for (index, signature) in signatures.enumerated() {
            for value in signature {
                postings.append((value, Int32(index)))
            }
        }
        guard !postings.isEmpty else { return [] }

        postings.sort { lhs, rhs in
            lhs.value == rhs.value ? lhs.track < rhs.track : lhs.value < rhs.value
        }

        // Walk each run of equal values and count co-occurrences.
        var sharedCounts: [UInt64: Int] = [:]
        var runStart = 0

        while runStart < postings.count {
            var runEnd = runStart
            let value = postings[runStart].value
            while runEnd < postings.count, postings[runEnd].value == value {
                runEnd += 1
            }
            defer { runStart = runEnd }

            let runLength = runEnd - runStart
            guard runLength > 1, runLength <= maxPostingsPerValue else { continue }

            for i in runStart..<(runEnd - 1) {
                for j in (i + 1)..<runEnd {
                    let low = UInt64(UInt32(bitPattern: postings[i].track))
                    let high = UInt64(UInt32(bitPattern: postings[j].track))
                    sharedCounts[(low << 32) | high, default: 0] += 1
                }
            }
        }

        return sharedCounts.compactMap { key, count in
            guard count >= minShared else { return nil }
            return (Int(key >> 32), Int(key & 0xffff_ffff))
        }
    }
}
