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

        public init(title: String?, artist: String?) {
            self.title = title
            self.artist = artist
        }
    }

    public static func readTags(from url: URL) async -> Tags {
        let asset = AVURLAsset(url: url)
        do {
            let items = try await asset.load(.commonMetadata)
            let title = await stringValue(for: .commonKeyTitle, in: items)
            let artist = await stringValue(for: .commonKeyArtist, in: items)
            return Tags(title: title, artist: artist)
        } catch {
            return Tags(title: nil, artist: nil)
        }
    }

    private static func stringValue(for key: AVMetadataKey, in items: [AVMetadataItem]) async -> String? {
        let matching = AVMetadataItem.metadataItems(from: items, withKey: key, keySpace: .common)
        guard let item = matching.first else { return nil }
        let value = try? await item.load(.stringValue)
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        return (trimmed?.isEmpty ?? true) ? nil : trimmed
    }
}
