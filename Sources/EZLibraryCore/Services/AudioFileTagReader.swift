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
import AVFoundation

/// Reads title/artist tags from an audio file using AVFoundation's common
/// metadata, so downloaded/purchased files can be matched even when their
/// filename doesn't carry the artist/title. Works across mp3 (ID3), m4a/aac,
/// flac, wav, aiff, etc.
public enum AudioFileTagReader {
    public struct Tags: Sendable, Equatable {
        public let title: String?
        public let artist: String?
        public let album: String?
        public let genre: String?
        public let year: Int?

        public var isEmpty: Bool {
            title == nil && artist == nil && album == nil && genre == nil && year == nil
        }

        public init(
            title: String?,
            artist: String?,
            album: String? = nil,
            genre: String? = nil,
            year: Int? = nil
        ) {
            self.title = title
            self.artist = artist
            self.album = album
            self.genre = genre
            self.year = year
        }
    }

    public static func readTags(from url: URL) async -> Tags {
        let asset = AVURLAsset(url: url)
        do {
            let items = try await asset.load(.commonMetadata)
            // The release year is not part of common metadata for every
            // container — an ID3 `TDRC`/`TYER` frame surfaces only in the
            // format-specific list — so that is loaded separately.
            let formatSpecific = (try? await asset.load(.metadata)) ?? []
            return Tags(
                title: await stringValue(for: .commonKeyTitle, in: items),
                artist: await stringValue(for: .commonKeyArtist, in: items),
                album: await stringValue(for: .commonKeyAlbumName, in: items),
                genre: await stringValue(for: .commonKeyType, in: items),
                year: await yearValue(common: items, formatSpecific: formatSpecific)
            )
        } catch {
            return Tags(title: nil, artist: nil)
        }
    }

    /// A release date can be a bare year, a full date, or a timestamp, so take
    /// the first four-digit run rather than trying to parse a date out of it.
    private static func yearValue(
        common: [AVMetadataItem],
        formatSpecific: [AVMetadataItem]
    ) async -> Int? {
        for key in [AVMetadataKey.commonKeyCreationDate, .commonKeyLastModifiedDate] {
            if let year = await yearFromString(await stringValue(for: key, in: common)) {
                return year
            }
        }

        let identifiers: [AVMetadataIdentifier] = [
            .id3MetadataRecordingTime,
            .id3MetadataYear,
            .id3MetadataDate,
            .iTunesMetadataReleaseDate,
            .quickTimeMetadataYear
        ]

        for identifier in identifiers {
            let matching = AVMetadataItem.metadataItems(from: formatSpecific, filteredByIdentifier: identifier)
            guard let item = matching.first else { continue }
            if let year = await yearFromString(try? await item.load(.stringValue)) {
                return year
            }
        }

        return nil
    }

    private static func yearFromString(_ raw: String?) async -> Int? {
        guard let raw, let match = raw.range(of: #"\d{4}"#, options: .regularExpression) else { return nil }
        guard let year = Int(raw[match]), (1000...9999).contains(year) else { return nil }
        return year
    }

    private static func stringValue(for key: AVMetadataKey, in items: [AVMetadataItem]) async -> String? {
        let matching = AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common)
        guard let item = matching.first else { return nil }
        let value = try? await item.load(.stringValue)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
