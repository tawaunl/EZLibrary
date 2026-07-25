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

private func randomFingerprint(seed: UInt64, frames: Int = 948) -> AudioFingerprint {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1
    var hashes: [UInt32] = []
    hashes.reserveCapacity(frames)
    for _ in 0..<frames {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        hashes.append(UInt32(truncatingIfNeeded: state >> 32))
    }
    return AudioFingerprint(duration: 200, hashes: hashes)
}

@Test func signatureHasRequestedSize() {
    let signature = AudioFingerprintIndex.signature(for: randomFingerprint(seed: 1), size: 64)
    #expect(signature.count == 64)
    #expect(signature == signature.sorted())
}

@Test func signatureOfEmptyFingerprintIsEmpty() {
    #expect(AudioFingerprintIndex.signature(for: AudioFingerprint(duration: 0, hashes: [])).isEmpty)
}

@Test func signatureIsStableUnderATimeShift() {
    // Choosing values by rank rather than position is what makes a trimmed or
    // padded lead-in survivable.
    let original = randomFingerprint(seed: 5)
    let shifted = AudioFingerprint(duration: 200, hashes: Array(original.hashes.dropFirst(40)))

    let a = Set(AudioFingerprintIndex.signature(for: original))
    let b = Set(AudioFingerprintIndex.signature(for: shifted))
    #expect(a.intersection(b).count >= 32)
}

@Test func unrelatedFingerprintsShareNoSignatureValues() {
    let a = Set(AudioFingerprintIndex.signature(for: randomFingerprint(seed: 11)))
    let b = Set(AudioFingerprintIndex.signature(for: randomFingerprint(seed: 12)))
    #expect(a.intersection(b).isEmpty)
}

@Test func candidatePairsFindDuplicatesAndIgnoreTheRest() {
    let original = randomFingerprint(seed: 21)
    let shifted = AudioFingerprint(duration: 200, hashes: Array(original.hashes.dropFirst(20)))

    let signatures = [
        AudioFingerprintIndex.signature(for: original),
        AudioFingerprintIndex.signature(for: shifted),
        AudioFingerprintIndex.signature(for: randomFingerprint(seed: 22)),
        AudioFingerprintIndex.signature(for: randomFingerprint(seed: 23))
    ]

    let pairs = AudioFingerprintIndex.candidatePairs(signatures: signatures)
    #expect(pairs.count == 1)
    let pair = pairs.first.map { [$0.0, $0.1].sorted() }
    #expect(pair == [0, 1])
}

@Test func candidatePairsHandleTrivialInput() {
    #expect(AudioFingerprintIndex.candidatePairs(signatures: []).isEmpty)
    #expect(AudioFingerprintIndex.candidatePairs(signatures: [[1, 2, 3]]).isEmpty)
    #expect(AudioFingerprintIndex.candidatePairs(signatures: [[], []]).isEmpty)
}

@Test func overCommonValuesAreIgnored() {
    // 150 tracks all sharing one value: that value says nothing about any
    // pair, and pairing the whole posting list would be 11k useless pairs.
    let shared: [UInt32] = [42]
    let signatures = Array(repeating: shared, count: 150)

    let pairs = AudioFingerprintIndex.candidatePairs(
        signatures: signatures,
        minShared: 1,
        maxPostingsPerValue: 100
    )
    #expect(pairs.isEmpty)
}

@Test func distinctiveValuesBelowTheCapStillPair() {
    // The same value on few enough tracks stays useful.
    let signatures: [[UInt32]] = [[7, 8, 9, 10], [7, 8, 9, 10], [1, 2, 3, 4]]
    let pairs = AudioFingerprintIndex.candidatePairs(
        signatures: signatures,
        minShared: 4,
        maxPostingsPerValue: 100
    )
    #expect(pairs.count == 1)
}

@Test func minimumSharedValuesIsEnforced() {
    let signatures: [[UInt32]] = [[1, 2, 3, 99], [1, 2, 3, 55]]
    #expect(AudioFingerprintIndex.candidatePairs(signatures: signatures, minShared: 3).count == 1)
    #expect(AudioFingerprintIndex.candidatePairs(signatures: signatures, minShared: 4).isEmpty)
}

@Test func libraryScanGroupsMatchingTracksAndFlagsTagMismatches() {
    let original = randomFingerprint(seed: 31)
    let copy = AudioFingerprint(duration: 200, hashes: Array(original.hashes.dropFirst(10)))
    let unrelated = randomFingerprint(seed: 32)

    func track(_ name: String, title: String, artist: String) -> Track {
        Track(
            seratoStoredPath: "Music/\(name).mp3",
            fileURL: URL(fileURLWithPath: "/tmp/\(name).mp3"),
            title: title,
            artist: artist
        )
    }

    let groups = FingerprintLibraryScanService.matchGroups(from: [
        (track: track("a", title: "Real Title", artist: "Real Artist"), fingerprint: original),
        (track: track("b", title: "Totally Wrong", artist: "Bad Tags"), fingerprint: copy),
        (track: track("c", title: "Something Else", artist: "Nobody"), fingerprint: unrelated)
    ])

    #expect(groups.count == 1)
    #expect(groups.first?.group.tracks.count == 2)
    // The tags disagree, so metadata matching would never have found this.
    #expect(groups.first?.status == .audioOnlyMatch)
}

@Test func libraryScanMarksMatchingTagsAsConfirmed() {
    let original = randomFingerprint(seed: 41)
    let copy = AudioFingerprint(duration: 200, hashes: Array(original.hashes.dropFirst(10)))

    func track(_ name: String) -> Track {
        Track(
            seratoStoredPath: "Music/\(name).mp3",
            fileURL: URL(fileURLWithPath: "/tmp/\(name).mp3"),
            title: "Anthem",
            artist: "Artist"
        )
    }

    let groups = FingerprintLibraryScanService.matchGroups(from: [
        (track: track("a"), fingerprint: original),
        (track: track("b"), fingerprint: copy)
    ])

    #expect(groups.count == 1)
    #expect(groups.first?.status == .audioConfirmed)
}
