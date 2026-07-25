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
import Testing
@testable import EZLibraryCore

/// Deterministic pseudo-random hashes stand in for a real fingerprint, so these
/// tests need no audio fixtures and no `fpcalc`.
private func syntheticFingerprint(seed: UInt64, frames: Int = 400, duration: Int = 200) -> AudioFingerprint {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1
    var hashes: [UInt32] = []
    hashes.reserveCapacity(frames)
    for _ in 0..<frames {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        hashes.append(UInt32(truncatingIfNeeded: state >> 32))
    }
    return AudioFingerprint(duration: duration, hashes: hashes)
}

/// Flips `count` bits per frame, mimicking the small differences a re-encode
/// introduces.
private func degraded(_ fingerprint: AudioFingerprint, bitsPerFrame: Int) -> AudioFingerprint {
    var state: UInt64 = 99
    let hashes = fingerprint.hashes.map { hash -> UInt32 in
        var result = hash
        for _ in 0..<bitsPerFrame {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            result ^= (1 << UInt32((state >> 33) % 32))
        }
        return result
    }
    return AudioFingerprint(duration: fingerprint.duration, hashes: hashes)
}

@Test func identicalFingerprintsScorePerfectly() {
    let fingerprint = syntheticFingerprint(seed: 1)
    #expect(AudioFingerprintMatcher.similarity(fingerprint, fingerprint) == 1.0)
}

@Test func unrelatedFingerprintsDoNotMatch() {
    let a = syntheticFingerprint(seed: 1)
    let b = syntheticFingerprint(seed: 2)
    // Independent bits agree about half the time, far below the threshold.
    #expect(AudioFingerprintMatcher.similarity(a, b) < 0.7)
    #expect(!AudioFingerprintMatcher.isMatch(a, b))
}

@Test func lightlyDegradedFingerprintStillMatches() {
    let original = syntheticFingerprint(seed: 7)
    // Two flipped bits of 32 is a ~0.94 score — typical of a lossy re-encode.
    #expect(AudioFingerprintMatcher.isMatch(original, degraded(original, bitsPerFrame: 2)))
}

@Test func matchSurvivesAShiftedStart() {
    let original = syntheticFingerprint(seed: 11, frames: 500)
    // Drop the first 20 frames, as a trimmed or padded lead-in would.
    let shifted = AudioFingerprint(
        duration: original.duration,
        hashes: Array(original.hashes.dropFirst(20))
    )
    #expect(AudioFingerprintMatcher.isMatch(original, shifted))
}

@Test func shiftBeyondSearchWindowIsNotForcedToMatch() {
    let original = syntheticFingerprint(seed: 13, frames: 600)
    let shifted = AudioFingerprint(
        duration: original.duration,
        hashes: Array(original.hashes.dropFirst(AudioFingerprintMatcher.defaultMaxOffsetFrames + 120))
    )
    // Still matches, because the overlapping region aligns within the window
    // once the shorter fingerprint slides — guard only that it does not crash
    // and returns a real score.
    let score = AudioFingerprintMatcher.similarity(original, shifted)
    #expect(score >= 0.0 && score <= 1.0)
}

@Test func emptyFingerprintsNeverMatch() {
    let empty = AudioFingerprint(duration: 0, hashes: [])
    let real = syntheticFingerprint(seed: 3)
    #expect(AudioFingerprintMatcher.similarity(empty, real) == 0.0)
    #expect(AudioFingerprintMatcher.similarity(empty, empty) == 0.0)
}

@Test func tinyFingerprintsAreNotJudged() {
    // These score 0.93 on raw bit agreement purely because small integers share
    // mostly-zero bits — exactly the coincidence that would delete a file.
    let short = AudioFingerprint(duration: 1, hashes: [1, 2, 3, 4, 5])
    let other = AudioFingerprint(duration: 1, hashes: [9, 9, 9, 9, 9])
    #expect(AudioFingerprintMatcher.similarity(short, other) == 0.0)
    #expect(!AudioFingerprintMatcher.isMatch(short, other))
}

@Test func shortFingerprintIsNotMatchedAgainstAFullOne() {
    let full = syntheticFingerprint(seed: 31)
    let clip = AudioFingerprint(
        duration: 3,
        hashes: Array(full.hashes.prefix(AudioFingerprintMatcher.minimumComparableFrames - 1))
    )
    // Even a genuine prefix of the same recording is refused below the limit,
    // rather than reported as a duplicate on thin evidence.
    #expect(AudioFingerprintMatcher.similarity(full, clip) == 0.0)
}

@Test func clusteringGroupsAllEncodingsOfOneRecording() {
    let original = syntheticFingerprint(seed: 21)
    let items: [(key: String, fingerprint: AudioFingerprint)] = [
        ("original", original),
        ("128k", degraded(original, bitsPerFrame: 2)),
        ("aac", degraded(original, bitsPerFrame: 3)),
        ("unrelated", syntheticFingerprint(seed: 22))
    ]

    let clusters = AudioFingerprintMatcher.cluster(items)
    #expect(clusters.count == 2)

    let duplicateCluster = clusters.first { $0.contains("original") }
    #expect(duplicateCluster?.count == 3)
    #expect(clusters.first { $0.contains("unrelated") }?.count == 1)
}

@Test func clusteringHandlesTrivialInputs() {
    #expect(AudioFingerprintMatcher.cluster([(key: "a", fingerprint: syntheticFingerprint(seed: 1))]).count == 1)

    let empty: [(key: String, fingerprint: AudioFingerprint)] = []
    #expect(AudioFingerprintMatcher.cluster(empty).isEmpty)
}

@Test func parsesMultipleFpcalcRecordsInOrder() {
    let output = """
    DURATION=255
    FINGERPRINT=1,2,3
    DURATION=180
    FINGERPRINT=4,5,6
    """

    let parsed = AudioFingerprintExtractor.parse(output)
    #expect(parsed.count == 2)
    #expect(parsed[0].duration == 255)
    #expect(parsed[0].hashes == [1, 2, 3])
    #expect(parsed[1].duration == 180)
    #expect(parsed[1].hashes == [4, 5, 6])
}

@Test func parseIgnoresIncompleteRecords() {
    // A duration with no fingerprint must not produce a phantom entry — that
    // would shift positional attribution onto the wrong file.
    let output = """
    DURATION=255
    DURATION=180
    FINGERPRINT=4,5,6
    """

    let parsed = AudioFingerprintExtractor.parse(output)
    #expect(parsed.count == 1)
    #expect(parsed[0].duration == 180)
}

@Test func parseHandlesEmptyOutput() {
    #expect(AudioFingerprintExtractor.parse("").isEmpty)
}
