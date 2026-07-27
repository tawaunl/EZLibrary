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
import Dispatch

/// Parses Serato's binary `database V2` track database format: a flat
/// sequence of tagged chunks (see `SeratoChunkCodec`), where each `otrk`
/// chunk is itself a nested sequence of per-field chunks.
///
/// Field tags below were cross-checked against Mixxx's open-source Serato
/// database reader (`src/library/serato/seratofeature.cpp`).
///
/// Performance: for large libraries (tens of thousands of tracks) the field
/// decode dominates load time, so the hot path avoids per-field allocations
/// entirely — it scans each `otrk` payload's chunks by byte offset (no
/// intermediate `[String: Data]` dictionary, no per-chunk `Data` copies, no
/// tag `String`s) and decodes the independent records in parallel.
public enum SeratoDatabaseParser {
    public enum ParserError: Error {
        case fileNotFound(URL)
    }

    /// Parses every `otrk` record in `fileURL`, resolving each track's
    /// stored path against `rootDirectory` (see
    /// `SeratoLibraryLocator.rootDirectory`).
    public static func parseTracks(at fileURL: URL, rootDirectory: URL) throws -> [Track] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ParserError.fileNotFound(fileURL)
        }
        // Memory-map when possible so a 50K-track database doesn't force a
        // full copy of the file into resident memory just to parse it.
        let data = try Data(contentsOf: fileURL, options: .mappedIfSafe)
        return parseTracks(from: data, rootDirectory: rootDirectory)
    }

    public static func parseTracks(from data: Data, rootDirectory: URL) -> [Track] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Track] in
            guard raw.baseAddress != nil else { return [] }
            let count = raw.count

            // 1. Collect the byte range of every top-level `otrk` payload
            //    without copying any bytes.
            var ranges: [(start: Int, length: Int)] = []
            var offset = 0
            while offset + 8 <= count {
                let tag = readTag(raw, offset)
                let size = readSize(raw, offset + 4)
                let payloadStart = offset + 8
                let payloadEnd = payloadStart + size
                guard payloadEnd <= count else { break }
                if tag == tagOtrk {
                    ranges.append((payloadStart, size))
                }
                offset = payloadEnd
            }

            guard !ranges.isEmpty else { return [] }

            // 2. Decode the independent records in parallel, preserving order
            //    by writing into a preallocated, index-addressed buffer. The
            //    shared buffers are only ever read (input) or written at
            //    disjoint indices (output), so the unchecked-Sendable escape
            //    hatch is safe here.
            let frozenRanges = ranges
            var decoded = [Track?](repeating: nil, count: frozenRanges.count)
            decoded.withUnsafeMutableBufferPointer { out in
                nonisolated(unsafe) let outBuffer = out
                nonisolated(unsafe) let inBuffer = raw
                DispatchQueue.concurrentPerform(iterations: frozenRanges.count) { index in
                    let range = frozenRanges[index]
                    outBuffer[index] = decodeTrack(
                        raw: inBuffer,
                        start: range.start,
                        length: range.length,
                        rootDirectory: rootDirectory
                    )
                }
            }

            return decoded.compactMap { $0 }
        }
    }

    // MARK: - Per-record decode

    /// Decodes a single `otrk` payload directly from the shared buffer,
    /// remembering each field's byte range on the first occurrence (matching
    /// the previous first-wins behavior) and decoding lazily afterward.
    private static func decodeTrack(
        raw: UnsafeRawBufferPointer,
        start: Int,
        length: Int,
        rootDirectory: URL
    ) -> Track? {
        let end = start + length
        var offset = start

        var rPfil, rTsng, rTart, rTalb, rTgen, rTcom, rTgrp, rTlbl: Range<Int>?
        var rTtyr, rTlen, rTbit, rTsmp, rTbpm, rTkey: Range<Int>?
        var rUtkn, rUlbl, rBbgl, rBmis, rUadd: Range<Int>?

        while offset + 8 <= end {
            let tag = readTag(raw, offset)
            let size = readSize(raw, offset + 4)
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= end else { break }
            let range = payloadStart..<payloadEnd

            switch tag {
            case tagPfil: if rPfil == nil { rPfil = range }
            case tagTsng: if rTsng == nil { rTsng = range }
            case tagTart: if rTart == nil { rTart = range }
            case tagTalb: if rTalb == nil { rTalb = range }
            case tagTgen: if rTgen == nil { rTgen = range }
            case tagTcom: if rTcom == nil { rTcom = range }
            case tagTgrp: if rTgrp == nil { rTgrp = range }
            case tagTlbl: if rTlbl == nil { rTlbl = range }
            case tagTtyr: if rTtyr == nil { rTtyr = range }
            case tagTlen: if rTlen == nil { rTlen = range }
            case tagTbit: if rTbit == nil { rTbit = range }
            case tagTsmp: if rTsmp == nil { rTsmp = range }
            case tagTbpm: if rTbpm == nil { rTbpm = range }
            case tagTkey: if rTkey == nil { rTkey = range }
            case tagUtkn: if rUtkn == nil { rUtkn = range }
            case tagUlbl: if rUlbl == nil { rUlbl = range }
            case tagBbgl: if rBbgl == nil { rBbgl = range }
            case tagBmis: if rBmis == nil { rBmis = range }
            case tagUadd: if rUadd == nil { rUadd = range }
            default: break
            }
            offset = payloadEnd
        }

        // Serato uses the file path as the track's identity; a record without
        // one can't be referenced by crates and is unusable.
        guard let pfilRange = rPfil else { return nil }
        let seratoStoredPath = decodeUTF16BE(raw, pfilRange)
        guard !seratoStoredPath.isEmpty else { return nil }

        return Track(
            seratoStoredPath: seratoStoredPath,
            fileURL: SeratoLibraryLocator.resolve(seratoStoredPath: seratoStoredPath, rootDirectory: rootDirectory),
            title: string(raw, rTsng),
            artist: string(raw, rTart),
            album: string(raw, rTalb),
            genre: string(raw, rTgen),
            comment: string(raw, rTcom),
            grouping: string(raw, rTgrp),
            label: string(raw, rTlbl),
            year: rTtyr.flatMap { Int(decodeUTF16BE(raw, $0)) },
            duration: rTlen.flatMap { TimeInterval(decodeUTF16BE(raw, $0)) },
            bitrate: rTbit.map { decodeUTF16BE(raw, $0) },
            sampleRate: rTsmp.map { decodeUTF16BE(raw, $0) },
            bpm: rTbpm.flatMap { Double(decodeUTF16BE(raw, $0)) },
            key: rTkey.map { decodeUTF16BE(raw, $0) },
            trackNumber: rUtkn.flatMap { uint16(raw, $0) }.map(Int.init),
            colorCode: rUlbl.flatMap { colorValue(raw, $0) },
            isBeatgridLocked: rBbgl.map { boolValue(raw, $0) } ?? false,
            isMissing: rBmis.map { boolValue(raw, $0) } ?? false,
            dateAdded: rUadd.flatMap { uint32(raw, $0) }.map { Date(timeIntervalSince1970: TimeInterval($0)) }
        )
    }

    // MARK: - Field decoders (operate on the shared buffer + a byte range)

    private static func string(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>?) -> String {
        range.map { decodeUTF16BE(raw, $0) } ?? ""
    }

    @inline(__always)
    private static func decodeUTF16BE(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> String {
        SeratoChunkCodec.decodeUTF16BE(raw, range)
    }

    private static func boolValue(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> Bool {
        guard range.count >= 1 else { return false }
        return raw[range.lowerBound] != 0
    }

    private static func uint16(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> UInt16? {
        guard range.count == 2 else { return nil }
        let i = range.lowerBound
        return (UInt16(raw[i]) << 8) | UInt16(raw[i + 1])
    }

    private static func uint32(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> UInt32? {
        guard range.count == 4 else { return nil }
        let i = range.lowerBound
        return (UInt32(raw[i]) << 24) | (UInt32(raw[i + 1]) << 16) | (UInt32(raw[i + 2]) << 8) | UInt32(raw[i + 3])
    }

    private static func colorValue(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> UInt32? {
        guard let value = uint32(raw, range) else { return nil }
        // Serato uses 0x00FFFFFF for "no color".
        return value == 0x00FF_FFFF ? nil : value
    }

    // MARK: - Raw readers

    @inline(__always)
    private static func readTag(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        SeratoChunkCodec.readTag(raw, offset)
    }

    @inline(__always)
    private static func readSize(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> Int {
        SeratoChunkCodec.readSize(raw, offset)
    }

    // MARK: - Four-character tag constants

    private static func fourCC(_ s: StaticString) -> UInt32 {
        SeratoChunkCodec.fourCC(s)
    }

    private static let tagOtrk = fourCC("otrk")
    private static let tagPfil = fourCC("pfil")
    private static let tagTsng = fourCC("tsng")
    private static let tagTart = fourCC("tart")
    private static let tagTalb = fourCC("talb")
    private static let tagTgen = fourCC("tgen")
    private static let tagTcom = fourCC("tcom")
    private static let tagTgrp = fourCC("tgrp")
    private static let tagTlbl = fourCC("tlbl")
    private static let tagTtyr = fourCC("ttyr")
    private static let tagTlen = fourCC("tlen")
    private static let tagTbit = fourCC("tbit")
    private static let tagTsmp = fourCC("tsmp")
    private static let tagTbpm = fourCC("tbpm")
    private static let tagTkey = fourCC("tkey")
    private static let tagUtkn = fourCC("utkn")
    private static let tagUlbl = fourCC("ulbl")
    private static let tagBbgl = fourCC("bbgl")
    private static let tagBmis = fourCC("bmis")
    private static let tagUadd = fourCC("uadd")
}
