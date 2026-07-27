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

/// A single tag/length/value record from Serato's binary file format
/// (`database V2` and `.crate`/`.scrate` files share this envelope).
///
/// Layout: 4-byte ASCII tag, 4-byte big-endian length, then `length` bytes
/// of payload. The payload is itself either a UTF-16BE string or a nested
/// sequence of chunks, depending on the tag.
public struct SeratoChunk: Equatable {
    public let tag: String
    public let payload: Data

    public init(tag: String, payload: Data) {
        self.tag = tag
        self.payload = payload
    }
}

public enum SeratoChunkCodec {
    /// Parses a flat sequence of chunks from `data`. Trailing bytes that
    /// don't form a complete chunk are ignored rather than throwing, since
    /// callers need to tolerate unknown/future record shapes.
    ///
    /// Reads through the raw buffer instead of materializing a `[UInt8]`
    /// copy of the whole file (and a second slice copy per chunk) — this
    /// runs once per `otrk` record on library load, so the copies dominated
    /// parse time for large `database V2` files.
    public static func readChunks(from data: Data) -> [SeratoChunk] {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [SeratoChunk] in
            guard let base = raw.baseAddress else { return [] }
            let count = raw.count
            var result: [SeratoChunk] = []
            var offset = 0
            while offset + 8 <= count {
                let tagBytes = UnsafeRawBufferPointer(start: base + offset, count: 4)
                let tag = String(decoding: tagBytes, as: UTF8.self)
                let size = Int(raw[offset + 4]) << 24
                    | Int(raw[offset + 5]) << 16
                    | Int(raw[offset + 6]) << 8
                    | Int(raw[offset + 7])
                let payloadStart = offset + 8
                let payloadEnd = payloadStart + size
                guard payloadEnd <= count else { break }
                result.append(SeratoChunk(tag: tag, payload: Data(bytes: base + payloadStart, count: size)))
                offset = payloadEnd
            }
            return result
        }
    }

    public static func writeChunk(tag: String, payload: Data) -> Data {
        precondition(tag.utf8.count == 4, "Serato chunk tags are exactly 4 ASCII bytes")
        var out = Data(tag.utf8)
        out.append(contentsOf: bigEndianBytes(UInt32(payload.count)))
        out.append(payload)
        return out
    }

    public static func writeChunk(_ chunk: SeratoChunk) -> Data {
        writeChunk(tag: chunk.tag, payload: chunk.payload)
    }

    public static func writeChunks(_ chunks: [SeratoChunk]) -> Data {
        var out = Data()
        for chunk in chunks {
            out.append(writeChunk(chunk))
        }
        return out
    }

    public static func decodeUTF16BEString(_ data: Data) -> String {
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> String in
            let unitCount = raw.count / 2
            guard unitCount > 0 else { return "" }
            var units = [UInt16](repeating: 0, count: unitCount)
            for i in 0..<unitCount {
                units[i] = (UInt16(raw[i * 2]) << 8) | UInt16(raw[i * 2 + 1])
            }
            return String(decoding: units, as: UTF16.self)
        }
    }

    public static func encodeUTF16BEString(_ string: String) -> Data {
        var data = Data()
        for unit in string.utf16 {
            data.append(UInt8(unit >> 8))
            data.append(UInt8(unit & 0xFF))
        }
        return data
    }

    private static func bigEndianBytes(_ value: UInt32) -> [UInt8] {
        [
            UInt8((value >> 24) & 0xFF),
            UInt8((value >> 16) & 0xFF),
            UInt8((value >> 8) & 0xFF),
            UInt8(value & 0xFF)
        ]
    }
}

// MARK: - Raw-buffer scanning primitives

/// Byte-level readers used by the parsers' hot paths, which walk a file's
/// chunks by offset instead of building `[SeratoChunk]` (one `Data` copy and
/// one tag `String` per chunk). On a large library that difference is tens of
/// thousands of allocations per load, so both `SeratoDatabaseParser` and
/// `SeratoCrateParser` decode straight out of the mapped buffer.
///
/// Deliberately module-internal: these hand back no bounds checking beyond
/// what the caller does itself, so they aren't part of the public API.
extension SeratoChunkCodec {
    /// Reads a 4-byte ASCII chunk tag as a single integer, so tag comparison
    /// is one integer compare rather than a `String` allocation + compare.
    @inline(__always)
    static func readTag(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> UInt32 {
        (UInt32(raw[offset]) << 24) | (UInt32(raw[offset + 1]) << 16)
            | (UInt32(raw[offset + 2]) << 8) | UInt32(raw[offset + 3])
    }

    /// Reads a chunk's 4-byte big-endian payload length.
    @inline(__always)
    static func readSize(_ raw: UnsafeRawBufferPointer, _ offset: Int) -> Int {
        (Int(raw[offset]) << 24) | (Int(raw[offset + 1]) << 16)
            | (Int(raw[offset + 2]) << 8) | Int(raw[offset + 3])
    }

    /// Decodes a UTF-16BE string directly from `range` of the shared buffer.
    static func decodeUTF16BE(_ raw: UnsafeRawBufferPointer, _ range: Range<Int>) -> String {
        let start = range.lowerBound
        let unitCount = range.count / 2
        guard unitCount > 0 else { return "" }

        // Fast path: pure ASCII (high byte 0, low byte < 0x80) is by far the
        // most common case for paths/titles and decodes without a UTF-16
        // intermediate buffer.
        var isASCII = true
        for i in 0..<unitCount where raw[start + i * 2] != 0 || raw[start + i * 2 + 1] >= 0x80 {
            isASCII = false
            break
        }
        if isASCII {
            var bytes = [UInt8](repeating: 0, count: unitCount)
            for i in 0..<unitCount {
                bytes[i] = raw[start + i * 2 + 1]
            }
            return String(decoding: bytes, as: UTF8.self)
        }

        var units = [UInt16](repeating: 0, count: unitCount)
        for i in 0..<unitCount {
            units[i] = (UInt16(raw[start + i * 2]) << 8) | UInt16(raw[start + i * 2 + 1])
        }
        return String(decoding: units, as: UTF16.self)
    }

    /// Compile-time-friendly conversion of a 4-character tag literal to the
    /// integer form `readTag` returns.
    static func fourCC(_ tag: StaticString) -> UInt32 {
        var result: UInt32 = 0
        tag.withUTF8Buffer { buffer in
            for byte in buffer { result = (result << 8) | UInt32(byte) }
        }
        return result
    }
}
