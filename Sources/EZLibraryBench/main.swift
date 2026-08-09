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
import EZLibraryCore

// Repeatable performance harness for large (50K-track) Serato libraries.
//
// Generates a realistic synthetic `database V2` + crates entirely in memory,
// then times the hot paths the app runs on launch and after every library
// change. Run in release for representative end-user numbers:
//
//     swift run -c release EZLibraryBench            # 50,000 tracks
//     swift run -c release EZLibraryBench 100000     # custom count
//
// No product code depends on this target; it exists purely for profiling.

@inline(__always)
func timeIt(_ label: String, _ body: () -> Void) {
    let start = DispatchTime.now().uptimeNanoseconds
    body()
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    print(String(format: "  %-38@ %9.1f ms", label as NSString, ms))
}

func bigEndian32(_ value: UInt32) -> Data {
    Data([
        UInt8((value >> 24) & 0xFF),
        UInt8((value >> 16) & 0xFF),
        UInt8((value >> 8) & 0xFF),
        UInt8(value & 0xFF)
    ])
}

/// Builds a realistic in-memory `database V2` blob with `count` `otrk`
/// records, mirroring the field set the app actually reads.
func makeSyntheticDatabase(trackCount count: Int) -> (data: Data, storedPaths: [String]) {
    let genres = ["House", "Techno", "Disco", "Hip Hop", "Pop", "Funk", "Soul",
                  "Drum & Bass", "Trance", "Ambient", "Rock", "Reggae",
                  "Afrobeat", "Latin", "R&B", "Electro", "Garage", "Dubstep",
                  "Breaks", "Downtempo"]
    let keys = ["1A", "2A", "3A", "4A", "5A", "6A", "7A", "8A", "9A", "10A", "11A", "12A"]

    var out = Data()
    out.append(SeratoChunkCodec.writeChunk(
        tag: "vrsn",
        payload: SeratoChunkCodec.encodeUTF16BEString("2.0/Serato Scratch LIVE Database")))

    var storedPaths: [String] = []
    storedPaths.reserveCapacity(count)
    out.reserveCapacity(count * 220)

    let baseDate = UInt32(Date().timeIntervalSince1970)

    for i in 0..<count {
        let path = "Music/Artist \(i % 5000)/Album \(i % 8000)/\(i) - Track Title Number \(i).mp3"
        storedPaths.append(path)

        var record = Data()
        func field(_ tag: String, _ value: String) {
            record.append(SeratoChunkCodec.writeChunk(
                tag: tag, payload: SeratoChunkCodec.encodeUTF16BEString(value)))
        }
        field("pfil", path)
        field("tsng", "Track Title Number \(i)")
        field("tart", "Artist \(i % 5000)")
        field("talb", "Album \(i % 8000)")
        field("tgen", genres[i % genres.count])
        field("tcom", "some comment text for track \(i)")
        field("tlbl", "Label \(i % 400)")
        field("ttyr", "\(1990 + (i % 35))")
        field("tlen", "\(180 + (i % 240))")
        field("tbit", "320")
        field("tsmp", "44100")
        field("tbpm", "\(120 + (i % 60)).0")
        field("tkey", keys[i % keys.count])
        record.append(SeratoChunkCodec.writeChunk(tag: "uadd", payload: bigEndian32(baseDate - UInt32(i))))

        out.append(SeratoChunkCodec.writeChunk(tag: "otrk", payload: record))
    }
    return (out, storedPaths)
}

/// Builds synthetic crates that collectively reference the given paths, with
/// two levels of nesting, to exercise `CrateHierarchy.build`.
func makeSyntheticCrates(storedPaths: [String], crateCount: Int) -> [Crate] {
    guard !storedPaths.isEmpty else { return [] }
    var crates: [Crate] = []
    crates.reserveCapacity(crateCount)
    let perCrate = max(1, storedPaths.count / crateCount)
    for c in 0..<crateCount {
        let start = (c * perCrate) % storedPaths.count
        let end = min(start + perCrate, storedPaths.count)
        let paths = Array(storedPaths[start..<end])
        crates.append(Crate(pathComponents: ["GENRE GROUP \(c % 12)", "Crate \(c)"], trackPaths: paths))
    }
    return crates
}

// MARK: - Run

let count = CommandLine.arguments.dropFirst().first.flatMap { Int($0) } ?? 50_000
let crateCount = 800

print("=== EZLibrary load benchmark @ \(count) tracks, \(crateCount) crates ===")

let (data, storedPaths) = makeSyntheticDatabase(trackCount: count)
print(String(format: "  database size: %.1f MB", Double(data.count) / 1_048_576))

let tempDir = FileManager.default.temporaryDirectory
    .appendingPathComponent("serato-bench-\(UUID().uuidString)", isDirectory: true)
try! FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: tempDir) }
let dbFile = tempDir.appendingPathComponent("database V2")
try! data.write(to: dbFile)
let root = URL(fileURLWithPath: "/Volumes/Library")

var fileData = Data()
timeIt("raw file read (Data(contentsOf:))") {
    fileData = try! Data(contentsOf: dbFile)
}

var topLevelCount = 0
timeIt("top-level readChunks (split otrk)") {
    topLevelCount = SeratoChunkCodec.readChunks(from: fileData).count
}
print("    (top-level chunks: \(topLevelCount))")

var tracks: [Track] = []
timeIt("parseTracks (disk read + decode)") {
    tracks = try! SeratoDatabaseParser.parseTracks(at: dbFile, rootDirectory: root)
}
precondition(tracks.count == count)

timeIt("derive trackGenres + artistCount") {
    _ = Array(Set(tracks.map(\.genre).filter { !$0.isEmpty })).sorted()
    _ = Set(tracks.map(\.artist).filter { !$0.isEmpty }).count
}

let crates = makeSyntheticCrates(storedPaths: storedPaths, crateCount: crateCount)

// Crate files are written to disk and parsed back, because reading and
// decoding them is a real part of every load — measuring only the in-memory
// `[Crate]` steps below hid what was once the single most expensive stage of
// a reload.
let crateDir = tempDir.appendingPathComponent("Subcrates", isDirectory: true)
try! FileManager.default.createDirectory(at: crateDir, withIntermediateDirectories: true)
var crateFiles: [URL] = []
for crate in crates {
    var data = SeratoChunkCodec.writeChunk(
        tag: "vrsn",
        payload: SeratoChunkCodec.encodeUTF16BEString("1.0/Serato ScratchLive Crate"))
    for path in crate.trackPaths {
        data.append(SeratoChunkCodec.writeChunk(
            tag: "otrk",
            payload: SeratoChunkCodec.writeChunk(
                tag: "ptrk", payload: SeratoChunkCodec.encodeUTF16BEString(path))))
    }
    let url = crateDir.appendingPathComponent(
        "\(Crate.fileBaseName(forPathComponents: crate.pathComponents)).crate")
    try! data.write(to: url)
    crateFiles.append(url)
}

var serialCrates: [Crate] = []
timeIt("load crates from disk — SERIAL") {
    serialCrates = crateFiles.compactMap { try? SeratoCrateParser.parseCrate(at: $0) }
}

var parallelCrates = [Crate?](repeating: nil, count: crateFiles.count)
timeIt("load crates from disk — PARALLEL (shipping)") {
    let files = crateFiles
    parallelCrates.withUnsafeMutableBufferPointer { out in
        nonisolated(unsafe) let outBuffer = out
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            outBuffer[index] = try? SeratoCrateParser.parseCrate(at: files[index])
        }
    }
}
precondition(serialCrates.map(\.trackPaths) == parallelCrates.map { $0?.trackPaths ?? [] },
             "parallel crate load must match serial")
print("    (\(serialCrates.count) crates, \(serialCrates.reduce(0) { $0 + $1.trackPaths.count }) track refs)")

timeIt("tracksInCratesCount (Set flatMap)") {
    _ = Set(crates.lazy.flatMap(\.trackPaths)).count
}

timeIt("CrateHierarchy.build") {
    _ = CrateHierarchy.build(from: crates)
}

// The full main-thread cost of one reload(): track parse + crate load from
// disk + both hierarchies + derived stats + tracksInCratesCount (the
// play-count scan is already async).
timeIt("FULL reload() equivalent (main-thread)") {
    let parsed = try! SeratoDatabaseParser.parseTracks(at: dbFile, rootDirectory: root)
    let files = crateFiles
    var loaded = [Crate?](repeating: nil, count: files.count)
    loaded.withUnsafeMutableBufferPointer { out in
        nonisolated(unsafe) let outBuffer = out
        DispatchQueue.concurrentPerform(iterations: files.count) { index in
            outBuffer[index] = try? SeratoCrateParser.parseCrate(at: files[index])
        }
    }
    let loadedCrates = loaded.compactMap { $0 }
    _ = Array(Set(parsed.map(\.genre).filter { !$0.isEmpty })).sorted()
    _ = Set(parsed.map(\.artist).filter { !$0.isEmpty }).count
    _ = Set(loadedCrates.lazy.flatMap(\.trackPaths)).count
    _ = CrateHierarchy.build(from: loadedCrates)
}

// MARK: - TrackTableView interaction costs (mirrors the app's logic)

print("--- table interaction (\(tracks.count) rows) ---")

// Filter (search) — lowercased contains across 4 fields, as computeDisplayedTracks does.
timeIt("filter contains (query 'the')") {
    let q = "the"
    _ = tracks.filter {
        $0.title.lowercased().contains(q)
            || $0.artist.lowercased().contains(q)
            || $0.genre.lowercased().contains(q)
            || $0.album.lowercased().contains(q)
    }
}

// Candidate A: case-insensitive range search (no per-field lowercased copy).
timeIt("filter range(of:caseInsensitive)") {
    let q = "the"
    _ = tracks.filter {
        $0.title.range(of: q, options: .caseInsensitive) != nil
            || $0.artist.range(of: q, options: .caseInsensitive) != nil
            || $0.genre.range(of: q, options: .caseInsensitive) != nil
            || $0.album.range(of: q, options: .caseInsensitive) != nil
    }
}

// Candidate B: precomputed lowercased blob per track (built once), then plain contains.
var blobs: [String] = []
timeIt("build lowercased blobs (ONCE per load)") {
    blobs = tracks.map {
        var s = $0.title; s += "\n"; s += $0.artist; s += "\n"; s += $0.genre; s += "\n"; s += $0.album
        return s.lowercased()
    }
}
timeIt("filter prebuilt blobs (per keystroke)") {
    let q = "the"
    _ = blobs.indices.filter { blobs[$0].contains(q) }
}

// Candidate C: precomputed lowercased UTF-8 BYTE blobs + byte substring search
// (avoids String.contains grapheme segmentation entirely).
func byteContains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
    guard !needle.isEmpty, needle.count <= haystack.count else { return false }
    let first = needle[0]
    let limit = haystack.count - needle.count
    var i = 0
    while i <= limit {
        if haystack[i] == first {
            var j = 1
            while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
            if j == needle.count { return true }
        }
        i += 1
    }
    return false
}

var byteBlobs: [[UInt8]] = []
timeIt("build lowercased BYTE blobs (ONCE per load)") {
    byteBlobs = tracks.map {
        var s = $0.title; s += "\u{01}"; s += $0.artist; s += "\u{01}"; s += $0.genre; s += "\u{01}"; s += $0.album
        return Array(s.lowercased().utf8)
    }
}
timeIt("filter BYTE blobs (per keystroke)") {
    let needle = Array("the".utf8)
    _ = byteBlobs.indices.filter { byteContains(byteBlobs[$0], needle) }
}
// A rarer query (fewer hits) to show worst-case scan cost.
timeIt("filter BYTE blobs (rare query)") {
    let needle = Array("zxqw".utf8)
    _ = byteBlobs.indices.filter { byteContains(byteBlobs[$0], needle) }
}

// Candidate D: NON-cached — build combined blob + byte-search per keystroke
// (what TrackTextSearch.filter does without a persisted index).
timeIt("filter combined byte (build+search/keystroke)") {
    let needle = Array("the".utf8)
    _ = tracks.filter { t in
        var s = t.title; s += "\u{01}"; s += t.artist; s += "\u{01}"; s += t.album; s += "\u{01}"; s += t.genre
        return byteContains(Array(s.lowercased().utf8), needle)
    }
}

// Sort by title using the locale-aware comparison the table uses today.
timeIt("sort title (localizedCaseInsensitive)") {
    _ = tracks.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
}

// Sort by a precomputed lowercased key (candidate optimization).
timeIt("sort title (precomputed lowercased)") {
    let keyed = tracks.map { (key: $0.title.lowercased(), track: $0) }
    _ = keyed.sorted { $0.key < $1.key }
}

// selectionKey mapping — runs once per recompute over the whole result set.
timeIt("selectionKey map (string transforms)") {
    _ = tracks.map {
        $0.seratoStoredPath
            .replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
    }
}

// Cached-index recompute (what TrackTableView now does): prebuild search bytes
// + selection key ONCE, then per keystroke filter + sort + extract (keys free).
struct Indexed { let track: Track; let bytes: [UInt8]; let key: String }
var indexed: [Indexed] = []
timeIt("build display index (ONCE per load)") {
    indexed = tracks.map { t in
        var s = t.title; s += "\u{01}"; s += t.artist; s += "\u{01}"; s += t.album; s += "\u{01}"; s += t.genre
        let key = t.seratoStoredPath.replacingOccurrences(of: "\\", with: "/")
            .trimmingCharacters(in: CharacterSet(charactersIn: "/")).lowercased()
        return Indexed(track: t, bytes: Array(s.lowercased().utf8), key: key)
    }
}
timeIt("cached recompute: filter+sort+extract/keystroke") {
    let needle = Array("the".utf8)
    let filtered = indexed.filter { byteContains($0.bytes, needle) }
    let sorted = filtered.sorted { $0.track.title.localizedCaseInsensitiveCompare($1.track.title) == .orderedAscending }
    _ = sorted.map(\.track)
    _ = sorted.map(\.key)
}

// TracksAndTagsView fill-count stats. These no longer run per SwiftUI body
// evaluation — they're part of the memoized `Derived` snapshot recomputed off
// the main actor — but that snapshot is rebuilt on every search keystroke, so
// the cost still sits on the interactive path.
//
// Old shape: 8 separate O(n) passes, each allocating a trimmed copy per track.
timeIt("stats: 8 passes x trimmingCharacters") {
    let ws = CharacterSet.whitespacesAndNewlines
    for _ in 0..<4 {
        _ = tracks.filter { !$0.artist.trimmingCharacters(in: ws).isEmpty }.count
    }
    _ = tracks.filter { !$0.album.trimmingCharacters(in: ws).isEmpty }.count
    _ = tracks.filter { !$0.genre.trimmingCharacters(in: ws).isEmpty }.count
    _ = tracks.filter { $0.year != nil }.count
    _ = tracks.filter { !$0.artist.trimmingCharacters(in: ws).isEmpty }.count
}

// Shipping shape: one fused pass over the array for all four fields, with an
// allocation-free whitespace test (see `TracksAndTagsView.fillCounts`).
timeIt("stats: 1 fused pass, no allocation") {
    @inline(__always) func hasContent(_ s: String) -> Bool {
        for scalar in s.unicodeScalars {
            switch scalar.value {
            case 0x20, 0x09, 0x0A, 0x0B, 0x0C, 0x0D: continue
            default:
                if scalar.value < 0x85 { return true }
                if !CharacterSet.whitespacesAndNewlines.contains(scalar) { return true }
            }
        }
        return false
    }
    // The view computes these twice: once for the scope, once for all tracks.
    for _ in 0..<2 {
        var artist = 0, album = 0, genre = 0, year = 0
        for track in tracks {
            if hasContent(track.artist) { artist += 1 }
            if hasContent(track.album) { album += 1 }
            if hasContent(track.genre) { genre += 1 }
            if track.year != nil { year += 1 }
        }
        _ = (artist, album, genre, year)
    }
}


// playCountSignature — O(n) sum recomputed on EVERY SwiftUI body evaluation.
timeIt("playCountSignature (per body eval!)") {
    var sum = 0
    for t in tracks { sum = sum &+ (t.playCount ?? 0) }
    _ = sum
}

// tracksDiffer — O(n) id+playCount compare on EVERY updateNSView pass.
timeIt("tracksDiffer (per updateNSView!)") {
    var differ = false
    for i in tracks.indices where tracks[i].id != tracks[i].id || tracks[i].playCount != tracks[i].playCount {
        differ = true
    }
    _ = differ
}


// MARK: - Audio trim editor
//
// The waveform view redraws on every playhead tick (20Hz while playing) and on
// every mouse move over the waveform, and each redraw reslices the stored
// envelope. These are the per-frame costs.

print("\nAudio trim editor — waveform envelope")

// A 6-minute track at the editor's 400 buckets/second.
let envelopeDuration: TimeInterval = 360
let envelopePeaks: [Float] = (0..<Int(envelopeDuration * 400)).map { index in
    Float(abs(sin(Double(index) / 900))) * 0.9
}
let envelope = AudioWaveform(peaks: envelopePeaks, duration: envelopeDuration)
print("  envelope: \(envelopePeaks.count) buckets, \(Int(envelopeDuration))s")

// ~1100 columns is what an 1650pt-wide waveform asks for at 1.5pt per column.
let columns = 1100

timeIt("peaks() fully zoomed out x60") {
    for _ in 0..<60 {
        _ = envelope.peaks(from: 0, to: envelopeDuration, bucketCount: columns)
    }
}

timeIt("peaks() at 32x zoom x60") {
    let visible = envelopeDuration / 32
    for _ in 0..<60 {
        _ = envelope.peaks(from: 100, to: 100 + visible, bucketCount: columns)
    }
}

timeIt("peaks() at 512x zoom x60") {
    let visible = envelopeDuration / 512
    for _ in 0..<60 {
        _ = envelope.peaks(from: 100, to: 100 + visible, bucketCount: columns)
    }
}

timeIt("loudBounds (silence detect)") {
    _ = AudioWaveformSampler.loudBounds(in: envelope)
}

// Decoding happens once per sheet open, on a real file. Point the bench at one
// with EZBENCH_AUDIO=/path/to/track.mp3 — skipped when unset so the default
// run stays dependency-free.
if let audioPath = ProcessInfo.processInfo.environment["EZBENCH_AUDIO"] {
    let audioURL = URL(fileURLWithPath: audioPath)
    print("\nAudio trim editor — decode \(audioURL.lastPathComponent)")

    let semaphore = DispatchSemaphore(value: 0)
    Task {
        for resolution in [
            ("totalBuckets(1200)", AudioWaveformSampler.Resolution.totalBuckets(1200)),
            ("perSecond(400)", AudioWaveformSampler.Resolution.perSecond(400)),
            ("perSecond(100)", AudioWaveformSampler.Resolution.perSecond(100))
        ] {
            let start = DispatchTime.now().uptimeNanoseconds
            let waveform = try? await AudioWaveformSampler.waveform(
                forFileAt: audioURL, resolution: resolution.1)
            let ms = Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
            let buckets = waveform?.peaks.count ?? 0
            print(String(format: "  %-38@ %9.1f ms  (%d buckets)",
                         resolution.0 as NSString, ms, buckets))
        }
        semaphore.signal()
    }
    // AVFoundation's async loading delivers on the main runloop, so blocking it
    // outright deadlocks. Pump instead of waiting.
    let deadline = Date().addingTimeInterval(120)
    while semaphore.wait(timeout: .now()) == .timedOut, Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.02))
    }
}

// The playback case: the window is fixed while the playhead moves, so every
// tick asks for the identical slice. Models the view's PeakCache.
print("")
final class BenchPeakCache {
    private var start = Double.nan, end = Double.nan, columns = -1
    private var cached: [Float] = []
    func peaks(of w: AudioWaveform, from s: Double, to e: Double, columns c: Int) -> [Float] {
        if s == start, e == end, c == columns { return cached }
        cached = w.peaks(from: s, to: e, bucketCount: c)
        (start, end, columns) = (s, e, c)
        return cached
    }
}
let benchCache = BenchPeakCache()
timeIt("20Hz playback, 1s uncached (zoomed out)") {
    for _ in 0..<20 { _ = envelope.peaks(from: 0, to: envelopeDuration, bucketCount: columns) }
}
timeIt("20Hz playback, 1s cached (zoomed out)") {
    for _ in 0..<20 {
        _ = benchCache.peaks(of: envelope, from: 0, to: envelopeDuration, columns: columns)
    }
}
