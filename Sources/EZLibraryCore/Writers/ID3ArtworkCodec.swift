import Foundation

/// Attached-picture (cover art) payload for an ID3 tag.
public struct ID3Artwork: Sendable, Hashable {
    public let mimeType: String
    /// ID3 picture type byte (0x03 = front cover).
    public let pictureType: UInt8
    public let imageData: Data

    public init(mimeType: String, pictureType: UInt8 = 0x03, imageData: Data) {
        self.mimeType = mimeType
        self.pictureType = pictureType
        self.imageData = imageData
    }
}

/// Reads and writes ID3 frames needed to preserve or replace cover art.
///
/// Parsing understands ID3v2.2 (`PIC`), v2.3 and v2.4 (`APIC`). Everything is
/// re-emitted as v2.4 frames so it stays consistent with the tag the metadata
/// editor writes. Frames using per-frame compression/encryption/unsynchronisation
/// flags are skipped rather than risk corrupting them.
public enum ID3ArtworkCodec {
    // MARK: - Public

    /// Returns the first usable cover-art picture in a full ID3 tag (including
    /// the 10-byte header), preferring the front-cover type when present.
    public static func extractArtwork(fromID3TagBytes tagData: Data) -> ID3Artwork? {
        guard let parsed = parseFrames(tagData) else { return nil }

        var fallback: ID3Artwork?
        for frame in parsed.frames where frame.canReemit {
            let artwork: ID3Artwork?
            if parsed.version == 2, frame.id == "PIC" {
                artwork = parsePIC(frame.body)
            } else if frame.id == "APIC" {
                artwork = parseAPIC(frame.body)
            } else {
                artwork = nil
            }

            guard let artwork else { continue }
            if artwork.pictureType == 0x03 {
                return artwork
            }
            if fallback == nil {
                fallback = artwork
            }
        }
        return fallback
    }

    /// Re-emits every v2.3/v2.4 frame from `tagData` as a v2.4 frame, excluding
    /// the given frame IDs and any picture frames (handled separately). ID3v2.2
    /// tags return no preserved frames because their 3-char IDs can't be mapped
    /// safely; their artwork is still carried over via `extractArtwork`.
    public static func preservedFrames(fromID3TagBytes tagData: Data, excludingFrameIDs excluded: Set<String>) -> Data {
        guard let parsed = parseFrames(tagData), parsed.version >= 3 else { return Data() }

        var out = Data()
        for frame in parsed.frames {
            guard frame.canReemit else { continue }
            if frame.id == "APIC" || frame.id == "PIC" { continue }
            if excluded.contains(frame.id) { continue }
            guard frame.id.count == 4, frame.id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else { continue }
            out.append(makeV24Frame(id: frame.id, body: frame.body))
        }
        return out
    }

    /// Builds a v2.4 `APIC` frame for the given artwork.
    public static func apicFrame(for artwork: ID3Artwork) -> Data {
        var body: [UInt8] = []
        body.append(0x03) // description text encoding: UTF-8
        body.append(contentsOf: Array(artwork.mimeType.data(using: .isoLatin1) ?? Data(artwork.mimeType.utf8)))
        body.append(0x00) // MIME terminator
        body.append(artwork.pictureType)
        body.append(0x00) // empty description terminator (UTF-8)
        body.append(contentsOf: artwork.imageData)
        return makeV24Frame(id: "APIC", body: body)
    }

    /// Returns the value of a user-defined text frame (`TXXX`, or `TXX` in
    /// ID3v2.2) whose description matches `description` (case-insensitively).
    /// Used to read Serato's play count, which it stores as a `SERATO_PLAYCOUNT`
    /// `TXXX` frame rather than in the `database V2` file.
    public static func userTextValue(fromID3TagBytes tagData: Data, description: String) -> String? {
        guard let parsed = parseFrames(tagData) else { return nil }
        for frame in parsed.frames where frame.canReemit {
            let isUserText = (parsed.version == 2 && frame.id == "TXX")
                || (parsed.version >= 3 && frame.id == "TXXX")
            guard isUserText, let parsedText = parseUserText(frame.body) else { continue }
            if parsedText.description.compare(description, options: .caseInsensitive) == .orderedSame {
                return parsedText.value
            }
        }
        return nil
    }

    /// Best-effort MIME sniffing from image magic bytes; defaults to JPEG.
    public static func mimeType(forImageData data: Data) -> String {
        let bytes = [UInt8](data.prefix(8))
        if bytes.count >= 3, bytes[0] == 0xFF, bytes[1] == 0xD8, bytes[2] == 0xFF {
            return "image/jpeg"
        }
        if bytes.count >= 4, bytes[0] == 0x89, bytes[1] == 0x50, bytes[2] == 0x4E, bytes[3] == 0x47 {
            return "image/png"
        }
        return "image/jpeg"
    }

    // MARK: - Frame parsing

    private struct RawFrame {
        let id: String
        /// Frame data normalised for re-emit: any data-length indicator
        /// stripped and unsynchronisation reversed, so callers get the real
        /// payload bytes regardless of how the source tag encoded them.
        let body: [UInt8]
        /// False when the frame is compressed/encrypted/grouped and can't be
        /// safely round-tripped; such frames are dropped rather than corrupted.
        let canReemit: Bool
    }

    private struct ParsedTag {
        let version: Int
        let frames: [RawFrame]
    }

    private static func parseFrames(_ tagData: Data) -> ParsedTag? {
        let bytes = [UInt8](tagData)
        guard bytes.count >= 10 else { return nil }
        guard bytes[0] == 0x49, bytes[1] == 0x44, bytes[2] == 0x33 else { return nil } // "ID3"

        let major = Int(bytes[3])
        let headerFlags = bytes[5]
        // Whole-tag unsynchronisation (ID3v2.3) is reversed per-frame below
        // rather than rejected, so Serato's GEOB cue/beatgrid frames survive
        // edits to tags that use it (previously this dropped every frame).
        let tagUnsync = headerFlags & 0x80 != 0

        let size = decodeSyncSafe(Array(bytes[6..<10]))
        let end = min(bytes.count, 10 + size)
        var pos = 10

        // Skip an extended header if present.
        if headerFlags & 0x40 != 0 {
            if major == 4, pos + 4 <= end {
                pos += decodeSyncSafe(Array(bytes[pos..<pos + 4]))
            } else if major == 3, pos + 4 <= end {
                pos += 4 + decodeUInt32BE(Array(bytes[pos..<pos + 4]))
            }
        }

        var frames: [RawFrame] = []

        if major == 2 {
            while pos + 6 <= end {
                if bytes[pos] == 0x00 { break } // padding
                let id = asciiString(Array(bytes[pos..<pos + 3]))
                let sz = decodeUInt24BE(Array(bytes[pos + 3..<pos + 6]))
                let bodyStart = pos + 6
                let bodyEnd = bodyStart + sz
                guard sz > 0, bodyEnd <= end else { break }
                let raw = Array(bytes[bodyStart..<bodyEnd])
                let body = tagUnsync ? reverseUnsynchronisation(raw) : raw
                frames.append(RawFrame(id: id, body: body, canReemit: true))
                pos = bodyEnd
            }
        } else if major == 3 || major == 4 {
            while pos + 10 <= end {
                if bytes[pos] == 0x00 { break } // padding
                let id = asciiString(Array(bytes[pos..<pos + 4]))
                let sizeSlice = Array(bytes[pos + 4..<pos + 8])
                let sz = major == 4 ? decodeSyncSafe(sizeSlice) : decodeUInt32BE(sizeSlice)
                let formatFlags = bytes[pos + 9]
                let bodyStart = pos + 10
                let bodyEnd = bodyStart + sz
                guard sz > 0, bodyEnd <= end else { break }
                let raw = Array(bytes[bodyStart..<bodyEnd])
                let normalized = normalizeFrameBody(
                    version: major,
                    formatFlags: formatFlags,
                    tagUnsync: tagUnsync,
                    rawBody: raw
                )
                frames.append(RawFrame(id: id, body: normalized.body, canReemit: normalized.canReemit))
                pos = bodyEnd
            }
        } else {
            return nil
        }

        return ParsedTag(version: major, frames: frames)
    }

    private static func parseAPIC(_ body: [UInt8]) -> ID3Artwork? {
        guard body.count > 4 else { return nil }
        let encoding = body[0]
        var i = 1

        var mimeBytes: [UInt8] = []
        while i < body.count, body[i] != 0x00 {
            mimeBytes.append(body[i])
            i += 1
        }
        guard i < body.count else { return nil }
        i += 1 // MIME terminator

        guard i < body.count else { return nil }
        let pictureType = body[i]
        i += 1

        i = skipDescription(body, from: i, encoding: encoding)
        guard i < body.count else { return nil }

        let image = Array(body[i..<body.count])
        guard !image.isEmpty else { return nil }
        let mime = asciiString(mimeBytes).isEmpty ? mimeType(forImageData: Data(image)) : asciiString(mimeBytes)
        return ID3Artwork(mimeType: mime, pictureType: pictureType, imageData: Data(image))
    }

    private static func parsePIC(_ body: [UInt8]) -> ID3Artwork? {
        guard body.count > 6 else { return nil }
        let encoding = body[0]
        let format = asciiString(Array(body[1..<4])).uppercased()
        let pictureType = body[4]
        let i = skipDescription(body, from: 5, encoding: encoding)
        guard i < body.count else { return nil }

        let image = Array(body[i..<body.count])
        guard !image.isEmpty else { return nil }

        let mime: String
        switch format {
        case "PNG":
            mime = "image/png"
        case "JPG", "JPE", "JPEG":
            mime = "image/jpeg"
        default:
            mime = mimeType(forImageData: Data(image))
        }
        return ID3Artwork(mimeType: mime, pictureType: pictureType, imageData: Data(image))
    }

    /// Splits a user-defined text frame (`TXXX`) body into its description and
    /// value, decoding both using the frame's text-encoding byte.
    private static func parseUserText(_ body: [UInt8]) -> (description: String, value: String)? {
        guard let encoding = body.first else { return nil }
        let content = Array(body.dropFirst())
        let split = splitFirstString(content, encoding: encoding)
        let description = decodeText(split.string, encoding: encoding)
        let value = decodeText(split.rest, encoding: encoding)
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (description, value)
    }

    /// Returns the first null-terminated string (per the encoding's terminator
    /// width) and the bytes following the terminator.
    private static func splitFirstString(_ bytes: [UInt8], encoding: UInt8) -> (string: [UInt8], rest: [UInt8]) {
        if encoding == 0x01 || encoding == 0x02 {
            var i = 0
            while i + 1 < bytes.count {
                if bytes[i] == 0x00, bytes[i + 1] == 0x00 {
                    return (Array(bytes[0..<i]), Array(bytes[(i + 2)...]))
                }
                i += 2
            }
            return (bytes, [])
        }
        if let terminator = bytes.firstIndex(of: 0x00) {
            return (Array(bytes[0..<terminator]), Array(bytes[(terminator + 1)...]))
        }
        return (bytes, [])
    }

    private static func decodeText(_ bytes: [UInt8], encoding: UInt8) -> String {
        let data = Data(bytes)
        switch encoding {
        case 0x00:
            return String(data: data, encoding: .isoLatin1) ?? ""
        case 0x01:
            return String(data: data, encoding: .utf16) ?? ""
        case 0x02:
            return String(data: data, encoding: .utf16BigEndian) ?? ""
        default:
            return String(data: data, encoding: .utf8) ?? ""
        }
    }

    private static func skipDescription(_ body: [UInt8], from start: Int, encoding: UInt8) -> Int {
        var i = start
        if encoding == 0x01 || encoding == 0x02 {
            // UTF-16 variants: terminated by 0x00 0x00.
            while i + 1 < body.count {
                if body[i] == 0x00, body[i + 1] == 0x00 {
                    i += 2
                    return i
                }
                i += 2
            }
            return body.count
        } else {
            // ISO-8859-1 / UTF-8: terminated by a single 0x00.
            while i < body.count, body[i] != 0x00 { i += 1 }
            if i < body.count { i += 1 }
            return i
        }
    }

    private static func makeV24Frame(id: String, body: [UInt8]) -> Data {
        var frame = Data(id.utf8)
        frame.append(contentsOf: encodeSyncSafe(body.count))
        frame.append(contentsOf: [0x00, 0x00]) // flags
        frame.append(contentsOf: body)
        return frame
    }

    // MARK: - Unsynchronisation & frame normalisation

    /// Reverses ID3 unsynchronisation: every `0xFF 0x00` pair inserted to
    /// avoid false MPEG sync signals is collapsed back to a single `0xFF`.
    private static func reverseUnsynchronisation(_ bytes: [UInt8]) -> [UInt8] {
        guard bytes.contains(0xFF) else { return bytes }
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            let byte = bytes[i]
            out.append(byte)
            if byte == 0xFF, i + 1 < bytes.count, bytes[i + 1] == 0x00 {
                i += 2
            } else {
                i += 1
            }
        }
        return out
    }

    /// Strips a v2.3/v2.4 frame's optional data-length indicator and reverses
    /// any unsynchronisation so the returned bytes are the real payload.
    /// Compressed, encrypted, or grouped frames can't be safely rebuilt and
    /// are reported as non-re-emittable so callers drop rather than corrupt them.
    private static func normalizeFrameBody(
        version: Int,
        formatFlags: UInt8,
        tagUnsync: Bool,
        rawBody: [UInt8]
    ) -> (body: [UInt8], canReemit: Bool) {
        if version == 4 {
            let grouping = formatFlags & 0x40 != 0
            let compressed = formatFlags & 0x08 != 0
            let encrypted = formatFlags & 0x04 != 0
            let frameUnsync = formatFlags & 0x02 != 0
            let hasDataLength = formatFlags & 0x01 != 0
            if grouping || compressed || encrypted {
                return (rawBody, false)
            }
            var body = rawBody
            if hasDataLength {
                guard body.count >= 4 else { return (rawBody, false) }
                body.removeFirst(4)
            }
            if frameUnsync || tagUnsync {
                body = reverseUnsynchronisation(body)
            }
            return (body, true)
        }

        // ID3v2.3 format flags: 0x80 compression, 0x40 encryption, 0x20 grouping.
        let compressed = formatFlags & 0x80 != 0
        let encrypted = formatFlags & 0x40 != 0
        let grouping = formatFlags & 0x20 != 0
        if compressed || encrypted || grouping {
            return (rawBody, false)
        }
        return (tagUnsync ? reverseUnsynchronisation(rawBody) : rawBody, true)
    }

    // MARK: - Integer codecs

    private static func decodeSyncSafe(_ b: [UInt8]) -> Int {
        guard b.count == 4 else { return 0 }
        return (Int(b[0] & 0x7F) << 21) | (Int(b[1] & 0x7F) << 14) | (Int(b[2] & 0x7F) << 7) | Int(b[3] & 0x7F)
    }

    private static func encodeSyncSafe(_ value: Int) -> [UInt8] {
        let v = max(0, value)
        return [
            UInt8((v >> 21) & 0x7F),
            UInt8((v >> 14) & 0x7F),
            UInt8((v >> 7) & 0x7F),
            UInt8(v & 0x7F)
        ]
    }

    private static func decodeUInt32BE(_ b: [UInt8]) -> Int {
        guard b.count == 4 else { return 0 }
        return (Int(b[0]) << 24) | (Int(b[1]) << 16) | (Int(b[2]) << 8) | Int(b[3])
    }

    private static func decodeUInt24BE(_ b: [UInt8]) -> Int {
        guard b.count == 3 else { return 0 }
        return (Int(b[0]) << 16) | (Int(b[1]) << 8) | Int(b[2])
    }

    private static func asciiString(_ b: [UInt8]) -> String {
        (String(bytes: b, encoding: .ascii) ?? "")
            .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
    }
}
