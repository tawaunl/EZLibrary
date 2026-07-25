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

private func baseFingerprint(seed: UInt64 = 77, frames: Int = 600) -> AudioFingerprint {
    var state = seed &* 6_364_136_223_846_793_005 &+ 1
    var hashes: [UInt32] = []
    for _ in 0..<frames {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        hashes.append(UInt32(truncatingIfNeeded: state >> 32))
    }
    return AudioFingerprint(duration: 200, hashes: hashes)
}

/// Flips `bitsPerFrame` bits per frame, standing in for a lossy re-encode.
private func degraded(_ fingerprint: AudioFingerprint, bitsPerFrame: Int, seed: UInt64 = 5) -> AudioFingerprint {
    var state = seed
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

private func track(_ file: String, title: String) -> Track {
    Track(
        seratoStoredPath: "Music/\(file)",
        fileURL: URL(fileURLWithPath: "/tmp/\(file)"),
        title: title,
        artist: "Blackstreet"
    )
}

@Test func versionsOfOneRecordingBecomeSeparateBranches() {
    // These all sound alike enough to cluster acoustically — that's exactly
    // why the version label has to keep them apart.
    let base = baseFingerprint()
    let cluster: [(track: Track, fingerprint: AudioFingerprint)] = [
        (track("nd-dirty.mp3", title: "No Diggity (Dirty)"), base),
        (track("nd-intro.mp3", title: "No Diggity (Intro Dirty)"), degraded(base, bitsPerFrame: 1)),
        (track("nd-qh.mp3", title: "No Diggity (Quick Hit Dirty)"), degraded(base, bitsPerFrame: 1, seed: 9)),
        (track("nd-qh2.mp3", title: "No Diggity (Quick Hit Dirty)"), degraded(base, bitsPerFrame: 1, seed: 9))
    ]

    let tree = TrackVersionTree.build(from: cluster)
    #expect(tree?.branches.count == 3)
    #expect(tree?.hasMultipleVersions == true)

    // Only the two Quick Hit copies are duplicates of each other.
    #expect(tree?.branchesWithDuplicates.count == 1)
    #expect(tree?.branchesWithDuplicates.first?.copies.count == 2)
    #expect(tree?.redundantCopyCount == 1)
}

@Test func aVersionWithOneCopyIsNeverRedundant() {
    let base = baseFingerprint()
    let cluster: [(track: Track, fingerprint: AudioFingerprint)] = [
        (track("a.mp3", title: "Anthem (Intro Clean)"), base),
        (track("b.mp3", title: "Anthem (Acapella)"), degraded(base, bitsPerFrame: 1))
    ]

    let tree = TrackVersionTree.build(from: cluster)
    #expect(tree?.branches.count == 2)
    #expect(tree?.redundantCopyCount == 0)
    #expect(tree?.branchesWithDuplicates.isEmpty == true)
    #expect(tree?.branches.allSatisfy { $0.confidence == .single } == true)
}

@Test func nearIdenticalCopiesAreSafeToAutoSelect() {
    let base = baseFingerprint()
    let cluster: [(track: Track, fingerprint: AudioFingerprint)] = [
        (track("a.mp3", title: "Anthem (Clean)"), base),
        (track("b.mp3", title: "Anthem (Clean)"), degraded(base, bitsPerFrame: 1))
    ]

    let branch = TrackVersionTree.build(from: cluster)?.branches.first
    #expect(branch?.copies.count == 2)
    #expect(branch?.confidence.isSafeToAutoSelect == true)
}

@Test func copiesThatAreOnlySimilarAreFlaggedForReview() {
    // Same version label, but far enough apart that a human should listen
    // before anything is deleted.
    let base = baseFingerprint()
    let cluster: [(track: Track, fingerprint: AudioFingerprint)] = [
        (track("a.mp3", title: "Anthem (Clean)"), base),
        (track("b.mp3", title: "Anthem (Clean)"), degraded(base, bitsPerFrame: 3))
    ]

    let branch = TrackVersionTree.build(from: cluster)?.branches.first
    #expect(branch?.copies.count == 2)
    #expect(branch?.confidence.isSafeToAutoSelect == false)
    if case .similar = branch?.confidence {
        // expected
    } else {
        Issue.record("expected .similar, got \(String(describing: branch?.confidence))")
    }
}

@Test func emptyClusterProducesNoTree() {
    #expect(TrackVersionTree.build(from: []) == nil)
}

// MARK: - Compound version labels

@Test func stemDescriptorsAreNotCollapsedIntoTheLyricCut() {
    // First-match-wins labelled this "Dirty", which put the acapella in the
    // same duplicate group as the full dirty mix.
    let full = track("nd.mp3", title: "No Diggity (Dirty)")
    let acapella = track("nd-aca.mp3", title: "No Diggity (Dirty Acapella)")

    #expect(DuplicateTracksService.versionLabel(for: full) != DuplicateTracksService.versionLabel(for: acapella))
    #expect(DuplicateTracksService.duplicateGroups(in: [full, acapella]).isEmpty)
}

@Test func editTypeAndLyricCutBothAppearInTheLabel() {
    let quickHit = track("qh.mp3", title: "No Diggity (Quick Hit Dirty)")
    #expect(DuplicateTracksService.versionLabel(for: quickHit).contains("Quick Hit"))
    #expect(DuplicateTracksService.versionLabel(for: quickHit).contains("Dirty"))
}

@Test func mixIsTreatedAsGenericSoItDoesNotSplitAVersion() {
    // "Extended Mix" and "Extended" are the same version in DJ naming.
    let a = track("a.mp3", title: "Anthem (Extended Mix)")
    let b = track("b.mp3", title: "Anthem Extended")
    #expect(DuplicateTracksService.versionLabel(for: a) == DuplicateTracksService.versionLabel(for: b))
}

@Test func untaggedTitlesStillLandOnOriginal() {
    #expect(DuplicateTracksService.versionLabel(for: track("a.mp3", title: "Anthem")) == "Original")
}
