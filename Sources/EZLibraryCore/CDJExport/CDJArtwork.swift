// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.
import AVFoundation
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Cover art for the stick: `PIONEER/Artwork/#####/a<id>.jpg` (80x80),
/// `a<id>_m.jpg` (240x240) and a `b` twin of each, twenty images to a folder.
///
/// The layout is the rbxport reference's; that the player derives the other
/// three names from the one the database names is its assumption too.
public struct CDJArtworkImage: Sendable, Equatable {
    public var id: UInt32
    /// The small image's path, which the database rows name: `/PIONEER/Artwork/00001/a1.jpg`.
    public var path: String
    public var small: Data
    public var medium: Data

    /// Every file this image puts on the stick, relative to the volume root.
    var files: [(relative: String, data: Data)] {
        let small = String(path.dropFirst())
        let medium = small.replacingOccurrences(of: ".jpg", with: "_m.jpg")
        return [
            (small, self.small), (medium, self.medium),
            (Self.twin(of: small), self.small), (Self.twin(of: medium), self.medium)
        ]
    }

    /// `…/a1.jpg` as `…/b1.jpg`.
    private static func twin(of relative: String) -> String {
        let name = (relative as NSString).lastPathComponent
        let folder = (relative as NSString).deletingLastPathComponent
        return folder + "/b" + name.dropFirst()
    }

    static func path(forID id: UInt32, root: String) -> String {
        String(format: "/%@/Artwork/%05d/a%d.jpg", root, Int(id / 20 + 1), Int(id))
    }
}

enum CDJArtwork {
    static let smallSide = 80
    static let mediumSide = 240

    private static let maxBlockBytes = 32 * 1024 * 1024

    /// The cover art embedded in an audio file, as the image bytes it holds.
    /// AVFoundation covers MP3 and M4A; FLAC picture blocks and the ID3 chunk
    /// of AIFF/WAV files it doesn't expose, so those are read directly.
    static func embeddedImage(in url: URL) async -> Data? {
        if let data = await avFoundationImage(in: url) { return data }
        switch url.pathExtension.lowercased() {
        case "flac": return flacPicture(at: url)
        case "aif", "aiff": return chunkedID3Picture(at: url, form: "FORM", bigEndian: true)
        case "wav": return chunkedID3Picture(at: url, form: "RIFF", bigEndian: false)
        default: return nil
        }
    }

    private static func avFoundationImage(in url: URL) async -> Data? {
        let asset = AVURLAsset(url: url)
        guard let items = try? await asset.load(.commonMetadata) else { return nil }
        for item in AVMetadataItem.metadataItems(from: items, filteredByIdentifier: .commonIdentifierArtwork) {
            if let data = try? await item.load(.dataValue), !data.isEmpty { return data }
        }
        return nil
    }

    /// The front cover (or, failing that, the first picture) of a FLAC file.
    static func flacPicture(at url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let magic = try? handle.read(upToCount: 4), magic == Data("fLaC".utf8) else { return nil }
        var first: Data?
        var offset: UInt64 = 4
        while let header = read(handle, at: offset, count: 4), header.count == 4 {
            let isLast = header[header.startIndex] & 0x80 != 0
            let type = header[header.startIndex] & 0x7F
            let length = header.dropFirst().reduce(0) { ($0 << 8) | Int($1) }
            if type == 6, length <= maxBlockBytes, let block = read(handle, at: offset + 4, count: length),
               let (pictureType, image) = pictureBlock([UInt8](block)) {
                if pictureType == 3 { return image }
                first = first ?? image
            }
            if isLast { break }
            offset += 4 + UInt64(length)
        }
        return first
    }

    /// A FLAC PICTURE block: type, MIME, description, size fields, then the image bytes.
    private static func pictureBlock(_ block: [UInt8]) -> (Int, Data)? {
        var cursor = 0
        func readUInt32() -> Int? {
            guard cursor + 4 <= block.count else { return nil }
            defer { cursor += 4 }
            return block[cursor..<(cursor + 4)].reduce(0) { ($0 << 8) | Int($1) }
        }
        guard let pictureType = readUInt32(), let mimeLength = readUInt32() else { return nil }
        cursor += mimeLength
        guard let descriptionLength = readUInt32() else { return nil }
        cursor += descriptionLength + 16  // width, height, depth, colour count
        guard cursor <= block.count, let dataLength = readUInt32(), dataLength > 0,
              cursor + dataLength <= block.count else { return nil }
        return (pictureType, Data(block[cursor..<(cursor + dataLength)]))
    }

    /// Cover art in the `ID3 ` chunk of an AIFF or WAV file.
    static func chunkedID3Picture(at url: URL, form: String, bigEndian: Bool) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let header = try? handle.read(upToCount: 12), header.count == 12,
              String(decoding: header.prefix(4), as: UTF8.self) == form else { return nil }
        var offset: UInt64 = 12
        while let chunk = read(handle, at: offset, count: 8), chunk.count == 8 {
            let id = String(decoding: chunk.prefix(4), as: UTF8.self).lowercased()
            let sizeBytes = Array(chunk.suffix(4))
            let size = bigEndian
                ? sizeBytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                : sizeBytes.reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            if id == "id3 " {
                guard size <= UInt64(maxBlockBytes), let tag = read(handle, at: offset + 8, count: Int(size)) else { return nil }
                return ID3ArtworkCodec.extractArtwork(fromID3TagBytes: tag)?.imageData
            }
            offset += 8 + size + (size % 2)
        }
        return nil
    }

    private static func read(_ handle: FileHandle, at offset: UInt64, count: Int) -> Data? {
        guard (try? handle.seek(toOffset: offset)) != nil else { return nil }
        return try? handle.read(upToCount: count)
    }

    /// Square JPEGs at both sizes, cropped from the middle, or nil if the bytes aren't an image.
    static func render(_ data: Data) -> (small: Data, medium: Data)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil),
              let small = jpeg(image, side: smallSide), let medium = jpeg(image, side: mediumSide) else { return nil }
        return (small, medium)
    }

    private static func jpeg(_ image: CGImage, side: Int) -> Data? {
        let shortSide = min(image.width, image.height)
        let crop = CGRect(
            x: (image.width - shortSide) / 2, y: (image.height - shortSide) / 2,
            width: shortSide, height: shortSide)
        guard let square = image.cropping(to: crop),
              let context = CGContext(
                  data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: 0,
                  space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        // Transparent covers would turn black in a JPEG.
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: side, height: side))
        context.draw(square, in: CGRect(x: 0, y: 0, width: side, height: side))
        guard let scaled = context.makeImage() else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(
            destination, scaled, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        return CGImageDestinationFinalize(destination) ? output as Data : nil
    }

    /// Reads every track's cover once, shares identical covers, and numbers the
    /// distinct ones from 1 in the order the tracks are given.
    static func collect(
        for sources: [(trackID: UInt32, url: URL)], root: String,
        reader: (URL) async -> Data? = { await CDJArtwork.embeddedImage(in: $0) }
    ) async -> (images: [CDJArtworkImage], byTrack: [UInt32: CDJArtworkImage]) {
        var images: [CDJArtworkImage] = []
        var byDigest: [String: CDJArtworkImage] = [:]
        var byTrack: [UInt32: CDJArtworkImage] = [:]
        for source in sources {
            guard let data = await reader(source.url) else { continue }
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            if let existing = byDigest[digest] {
                byTrack[source.trackID] = existing
                continue
            }
            guard let rendered = render(data) else { continue }
            let id = UInt32(images.count + 1)
            let image = CDJArtworkImage(
                id: id, path: CDJArtworkImage.path(forID: id, root: root),
                small: rendered.small, medium: rendered.medium)
            images.append(image)
            byDigest[digest] = image
            byTrack[source.trackID] = image
        }
        return (images, byTrack)
    }
}
