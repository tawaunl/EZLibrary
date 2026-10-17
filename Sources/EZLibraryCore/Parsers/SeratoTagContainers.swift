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

/// Finds Serato's analysis objects (`Serato Markers2`, `Serato BeatGrid`, …)
/// in whichever container an audio file uses to hold them.
///
/// - MP3: ID3 `GEOB` frames.
/// - AIFF / WAV: the same ID3 tag, inside an `ID3 ` / `id3 ` chunk.
/// - FLAC: `PICTURE` metadata blocks whose description is the object name.
/// - M4A / MP4: iTunes-style `----` atoms named `com.serato.dj` / `markers2`, etc.
///
/// Returns object payloads keyed by the canonical object name, with the
/// payload in the same shape the MP3 `GEOB` frame would hold.
enum SeratoTagContainers {
    static let markers2 = "Serato Markers2"
    static let beatgrid = "Serato BeatGrid"

    private static let maxContainerBytes = 64 * 1024 * 1024

    /// nil when the file's type isn't one we know how to read; an empty
    /// dictionary when it is but holds no Serato data.
    static func objects(forFileAt url: URL) -> [String: [UInt8]]? {
        switch url.pathExtension.lowercased() {
        case "mp3":
            guard let tag = ID3ArtworkCodec.readID3TagBytes(at: url) else { return [:] }
            return id3Objects(tag)
        case "aif", "aiff":
            return chunkedID3Objects(at: url, form: "FORM", bigEndian: true)
        case "wav":
            return chunkedID3Objects(at: url, form: "RIFF", bigEndian: false)
        case "flac":
            return flacObjects(at: url)
        case "m4a", "mp4":
            return mp4Objects(at: url)
        default:
            return nil
        }
    }

    /// Payloads in other containers can carry an extra base64 layer. Undo it
    /// when the payload doesn't already start with `prefix`.
    static func normalized(_ payload: [UInt8], expectingPrefix prefix: [UInt8]) -> [UInt8] {
        if payload.starts(with: prefix) { return payload }
        let text = payload.filter { $0 != 0x00 && $0 != 0x0A && $0 != 0x0D && $0 != 0x20 }
        guard !text.isEmpty else { return payload }
        var padded = text
        if padded.count % 4 == 1 { padded.removeLast() }
        while padded.count % 4 != 0 { padded.append(0x3D) }
        if let string = String(bytes: padded, encoding: .ascii), let data = Data(base64Encoded: string) {
            let decoded = [UInt8](data)
            if decoded.starts(with: prefix) { return decoded }
        }
        return payload
    }

    // MARK: - ID3 (MP3, and AIFF/WAV chunks)

    private static func id3Objects(_ tag: Data) -> [String: [UInt8]] {
        var result: [String: [UInt8]] = [:]
        for object in ID3ArtworkCodec.generalObjects(fromID3TagBytes: tag) {
            result[object.description] = object.payload
        }
        return result
    }

    private static func chunkedID3Objects(at url: URL, form: String, bigEndian: Bool) -> [String: [UInt8]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12,
              String(decoding: header.prefix(4), as: UTF8.self) == form else { return [:] }

        var offset: UInt64 = 12
        while let chunkHeader = readAt(handle, offset: offset, count: 8), chunkHeader.count == 8 {
            let id = String(decoding: chunkHeader.prefix(4), as: UTF8.self).lowercased()
            let sizeBytes = Array(chunkHeader.suffix(4))
            let size = bigEndian
                ? sizeBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                : sizeBytes.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            if id == "id3 " {
                guard size <= UInt64(maxContainerBytes),
                      let tag = readAt(handle, offset: offset + 8, count: Int(size)) else { return [:] }
                return id3Objects(tag)
            }
            offset += 8 + size + (size % 2)
        }
        return [:]
    }

    // MARK: - FLAC

    private static func flacObjects(at url: URL) -> [String: [UInt8]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return [:] }

        var result: [String: [UInt8]] = [:]
        var offset: UInt64 = 4
        while let header = readAt(handle, offset: offset, count: 4), header.count == 4 {
            let isLast = header[header.startIndex] & 0x80 != 0
            let type = header[header.startIndex] & 0x7F
            let length = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
            if type == 6, length <= maxContainerBytes,
               let block = readAt(handle, offset: offset + 4, count: length),
               let (description, data) = pictureBlock(Array(block)) {
                result[description] = data
            }
            if isLast { break }
            offset += 4 + UInt64(length)
        }
        return result
    }

    /// Reads a FLAC `PICTURE` block's description and data.
    private static func pictureBlock(_ block: [UInt8]) -> (String, [UInt8])? {
        var cursor = 4  // picture type
        func readUInt32() -> Int? {
            guard cursor + 4 <= block.count else { return nil }
            defer { cursor += 4 }
            return block[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        guard let mimeLength = readUInt32() else { return nil }
        cursor += mimeLength
        guard let descriptionLength = readUInt32(), cursor + descriptionLength <= block.count else { return nil }
        let description = String(decoding: block[cursor..<(cursor + descriptionLength)], as: UTF8.self)
        cursor += descriptionLength + 16  // width, height, depth, colour count
        guard let dataLength = readUInt32(), cursor + dataLength <= block.count else { return nil }
        return (description, Array(block[cursor..<(cursor + dataLength)]))
    }

    // MARK: - MP4

    private static func mp4Objects(at url: URL) -> [String: [UInt8]] {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return [:] }
        defer { try? handle.close() }

        var offset: UInt64 = 0
        while let header = readAt(handle, offset: offset, count: 16), header.count >= 8 {
            let bytes = [UInt8](header)
            var size = bytes[0..<4].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            var headerSize: UInt64 = 8
            if size == 1, bytes.count >= 16 {
                size = bytes[8..<16].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                headerSize = 16
            }
            guard size >= headerSize else { break }
            if String(decoding: bytes[4..<8], as: UTF8.self) == "moov" {
                let length = Int(size - headerSize)
                guard length <= maxContainerBytes,
                      let moov = readAt(handle, offset: offset + headerSize, count: length) else { return [:] }
                return mp4Metadata(Array(moov))
            }
            offset += size
        }
        return [:]
    }

    private static func mp4Boxes(_ bytes: ArraySlice<UInt8>) -> [(type: String, payload: ArraySlice<UInt8>)] {
        var boxes: [(String, ArraySlice<UInt8>)] = []
        var cursor = bytes.startIndex
        while cursor + 8 <= bytes.endIndex {
            let size = bytes[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
            let type = String(decoding: bytes[(cursor + 4)..<(cursor + 8)], as: UTF8.self)
            guard size >= 8, cursor + size <= bytes.endIndex else { break }
            boxes.append((type, bytes[(cursor + 8)..<(cursor + size)]))
            cursor += size
        }
        return boxes
    }

    private static func mp4Metadata(_ moov: [UInt8]) -> [String: [UInt8]] {
        guard let udta = mp4Boxes(moov[...]).first(where: { $0.type == "udta" }),
              let meta = mp4Boxes(udta.payload).first(where: { $0.type == "meta" }),
              let ilst = mp4Boxes(meta.payload.dropFirst(4)).first(where: { $0.type == "ilst" }) else { return [:] }

        var result: [String: [UInt8]] = [:]
        for item in mp4Boxes(ilst.payload) where item.type == "----" {
            let parts = mp4Boxes(item.payload)
            guard let name = parts.first(where: { $0.type == "name" }),
                  let data = parts.first(where: { $0.type == "data" }) else { continue }
            let label = String(decoding: name.payload.dropFirst(4), as: UTF8.self).lowercased()
            let value = Array(data.payload.dropFirst(8))  // version/flags + locale
            if label.contains("markers2") || label.contains("markersv2") {
                result[markers2] = value
            } else if label.contains("beatgrid") {
                result[beatgrid] = value
            }
        }
        return result
    }

    // MARK: - IO

    private static func readAt(_ handle: FileHandle, offset: UInt64, count: Int) -> Data? {
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count)
        } catch {
            return nil
        }
    }
}
