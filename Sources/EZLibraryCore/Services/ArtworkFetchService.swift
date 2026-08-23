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
import AppKit

/// Downloads cover art and turns it into an embeddable ID3 frame.
public enum ArtworkFetchService {
    public enum FetchError: LocalizedError {
        case notAnImage
        case tooLarge(Int)

        public var errorDescription: String? {
            switch self {
            case .notAnImage:
                return "The downloaded cover art was not a readable image."
            case let .tooLarge(bytes):
                let megabytes = Double(bytes) / 1_000_000
                return String(format: "The cover art is %.1f MB, which is too large to embed.", megabytes)
            }
        }
    }

    /// Cover art is embedded into every copy of the file's tag, so an
    /// unreasonably large image bloats the library for no visible benefit.
    /// Well above what any of the sources actually serve.
    public static let maximumBytes = 12_000_000

    public static func fetchArtwork(
        from url: URL,
        session: URLSession = .shared
    ) async throws -> ID3Artwork {
        let (data, _) = try await session.data(from: url)

        guard data.count <= maximumBytes else {
            throw FetchError.tooLarge(data.count)
        }
        // A source that has no art for a release often answers with an HTML
        // page or a placeholder rather than a 404, so the bytes are checked
        // rather than the status code.
        guard NSImage(data: data) != nil else {
            throw FetchError.notAnImage
        }

        return ID3Artwork(
            mimeType: ID3ArtworkCodec.mimeType(forImageData: data),
            imageData: data
        )
    }

    /// Whether the file already carries embedded cover art.
    ///
    /// Only meaningful for formats with an ID3 tag; anything else reports
    /// `false`, which is the safe answer — it makes art an offer rather than a
    /// silent replacement.
    public static func fileHasEmbeddedArtwork(at url: URL) -> Bool {
        guard let tagBytes = ID3ArtworkCodec.readID3TagBytes(at: url) else { return false }
        return ID3ArtworkCodec.extractArtwork(fromID3TagBytes: tagBytes) != nil
    }
}
