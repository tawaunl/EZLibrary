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

private func makeTempFile(contents: String = "audio bytes") -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("ezlib-fp-\(UUID().uuidString).mp3")
    try? contents.data(using: .utf8)?.write(to: url)
    return url
}

private func sampleFingerprint(frames: Int = 948) -> AudioFingerprint {
    var state: UInt64 = 42
    var hashes: [UInt32] = []
    for _ in 0..<frames {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        hashes.append(UInt32(truncatingIfNeeded: state >> 32))
    }
    return AudioFingerprint(duration: 255, hashes: hashes)
}

@Test func cacheRoundTripsThroughBinaryEncoding() {
    let url = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }

    var cache = AudioFingerprintCache()
    let fingerprint = sampleFingerprint()
    cache.store(fingerprint, for: url, analysisSeconds: 120)

    let decoded = AudioFingerprintCache.decode(cache.encode())
    #expect(decoded?.count == 1)
    #expect(decoded?.fingerprint(for: url, analysisSeconds: 120)?.hashes == fingerprint.hashes)
    #expect(decoded?.fingerprint(for: url, analysisSeconds: 120)?.duration == 255)
}

@Test func cacheMissesWhenAnalysisLengthDiffers() {
    let url = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }

    var cache = AudioFingerprintCache()
    cache.store(sampleFingerprint(), for: url, analysisSeconds: 120)

    // A 60s fingerprint is not comparable with a 120s one.
    #expect(cache.fingerprint(for: url, analysisSeconds: 60) == nil)
    #expect(cache.fingerprint(for: url, analysisSeconds: 120) != nil)
}

@Test func cacheInvalidatesWhenTheFileChanges() throws {
    let url = makeTempFile()
    defer { try? FileManager.default.removeItem(at: url) }

    var cache = AudioFingerprintCache()
    cache.store(sampleFingerprint(), for: url, analysisSeconds: 120)
    #expect(cache.fingerprint(for: url, analysisSeconds: 120) != nil)

    // Rewriting the file changes size and mtime, so the fingerprint is stale.
    try "audio bytes plus a re-tag".data(using: .utf8)!.write(to: url)
    #expect(cache.fingerprint(for: url, analysisSeconds: 120) == nil)
}

@Test func cacheMissesForDeletedFile() {
    let url = makeTempFile()
    var cache = AudioFingerprintCache()
    cache.store(sampleFingerprint(), for: url, analysisSeconds: 120)

    try? FileManager.default.removeItem(at: url)
    #expect(cache.fingerprint(for: url, analysisSeconds: 120) == nil)
}

@Test func partitionSplitsCachedFromMissing() {
    let cachedURL = makeTempFile()
    let missingURL = makeTempFile()
    defer {
        try? FileManager.default.removeItem(at: cachedURL)
        try? FileManager.default.removeItem(at: missingURL)
    }

    var cache = AudioFingerprintCache()
    cache.store(sampleFingerprint(), for: cachedURL, analysisSeconds: 120)

    let result = cache.partition([cachedURL, missingURL], analysisSeconds: 120)
    #expect(result.cached.count == 1)
    #expect(result.cached[cachedURL] != nil)
    #expect(result.missing == [missingURL])
}

@Test func pruneDropsEntriesOutsideTheLibrary() {
    let keep = makeTempFile()
    let drop = makeTempFile()
    defer {
        try? FileManager.default.removeItem(at: keep)
        try? FileManager.default.removeItem(at: drop)
    }

    var cache = AudioFingerprintCache()
    cache.store(sampleFingerprint(), for: keep, analysisSeconds: 120)
    cache.store(sampleFingerprint(), for: drop, analysisSeconds: 120)
    #expect(cache.count == 2)

    cache.prune(keeping: [keep.path])
    #expect(cache.count == 1)
    #expect(cache.fingerprint(for: keep, analysisSeconds: 120) != nil)
}

@Test func decodeRejectsGarbage() {
    #expect(AudioFingerprintCache.decode(Data()) == nil)
    #expect(AudioFingerprintCache.decode(Data("not a cache file at all".utf8)) == nil)
}

@Test func decodeKeepsWhatParsedBeforeTruncation() {
    let first = makeTempFile()
    let second = makeTempFile()
    defer {
        try? FileManager.default.removeItem(at: first)
        try? FileManager.default.removeItem(at: second)
    }

    var cache = AudioFingerprintCache()
    cache.store(sampleFingerprint(frames: 100), for: first, analysisSeconds: 120)
    cache.store(sampleFingerprint(frames: 100), for: second, analysisSeconds: 120)

    // A half-written cache must degrade to a partial one, never crash.
    let full = cache.encode()
    let truncated = full.prefix(full.count - 200)
    let decoded = AudioFingerprintCache.decode(Data(truncated))
    #expect(decoded != nil)
    #expect((decoded?.count ?? 99) < 2)
}

@Test func missingCacheFileLoadsEmpty() {
    let absent = FileManager.default.temporaryDirectory
        .appendingPathComponent("definitely-absent-\(UUID().uuidString).cache")
    #expect(AudioFingerprintCache.load(from: absent).count == 0)
}

@Test func cacheSavesAndLoadsFromDisk() throws {
    let audio = makeTempFile()
    let cacheURL = FileManager.default.temporaryDirectory
        .appendingPathComponent("ezlib-cache-\(UUID().uuidString).cache")
    defer {
        try? FileManager.default.removeItem(at: audio)
        try? FileManager.default.removeItem(at: cacheURL)
    }

    var cache = AudioFingerprintCache()
    cache.store(sampleFingerprint(), for: audio, analysisSeconds: 120)
    try cache.save(to: cacheURL)

    let reloaded = AudioFingerprintCache.load(from: cacheURL)
    #expect(reloaded.fingerprint(for: audio, analysisSeconds: 120)?.hashes.count == 948)
}

// MARK: - Duration gating

private func track(_ name: String, duration: TimeInterval?) -> Track {
    Track(
        seratoStoredPath: "Music/\(name).mp3",
        fileURL: URL(fileURLWithPath: "/tmp/\(name).mp3"),
        title: "Anthem",
        artist: "Artist",
        duration: duration
    )
}

@Test func durationGateSeparatesIncompatibleLengths() {
    let buckets = FingerprintDuplicateService.durationBuckets(for: [
        track("a", duration: 255),
        track("b", duration: 256),
        track("c", duration: 400)
    ])

    #expect(buckets.count == 2)
    #expect(buckets.contains { $0.count == 2 })
    #expect(buckets.contains { $0.count == 1 })
}

@Test func durationGateKeepsCloseLengthsTogether() {
    // A 2s silent lead-in must not separate a real duplicate.
    let buckets = FingerprintDuplicateService.durationBuckets(for: [
        track("a", duration: 255),
        track("b", duration: 257)
    ])
    #expect(buckets.count == 1)
}

@Test func durationGateDoesNotSplitWhenDurationIsUnknown() {
    // Missing duration must never cause a real duplicate pair to be skipped;
    // the gate is only an optimization.
    let buckets = FingerprintDuplicateService.durationBuckets(for: [
        track("a", duration: nil),
        track("b", duration: 400)
    ])
    #expect(buckets.count == 1)
    #expect(buckets[0].count == 2)
}
