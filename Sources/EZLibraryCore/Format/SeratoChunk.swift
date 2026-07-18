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
