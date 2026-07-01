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
    public static func readChunks(from data: Data) -> [SeratoChunk] {
        let bytes = [UInt8](data)
        var result: [SeratoChunk] = []
        var offset = 0
        while offset + 8 <= bytes.count {
            let tag = String(decoding: bytes[offset..<(offset + 4)], as: UTF8.self)
            let size = readUInt32BE(bytes, at: offset + 4)
            let payloadStart = offset + 8
            let payloadEnd = payloadStart + size
            guard payloadEnd <= bytes.count else { break }
            result.append(SeratoChunk(tag: tag, payload: Data(bytes[payloadStart..<payloadEnd])))
            offset = payloadEnd
        }
        return result
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
        var bytes = [UInt8](data)
        if bytes.count % 2 != 0 {
            bytes.removeLast()
        }
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = 0
        while i < bytes.count {
            units.append((UInt16(bytes[i]) << 8) | UInt16(bytes[i + 1]))
            i += 2
        }
        return String(decoding: units, as: UTF16.self)
    }

    public static func encodeUTF16BEString(_ string: String) -> Data {
        var data = Data()
        for unit in string.utf16 {
            data.append(UInt8(unit >> 8))
            data.append(UInt8(unit & 0xFF))
        }
        return data
    }

    private static func readUInt32BE(_ bytes: [UInt8], at offset: Int) -> Int {
        Int(bytes[offset]) << 24
            | Int(bytes[offset + 1]) << 16
            | Int(bytes[offset + 2]) << 8
            | Int(bytes[offset + 3])
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
