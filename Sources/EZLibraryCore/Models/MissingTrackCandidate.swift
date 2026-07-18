import Foundation

/// A track whose `fileURL` no longer exists on disk, plus any candidate
/// replacement files found by filename during a `FileSystemScanner` pass.
public struct MissingTrackCandidate: Identifiable, Hashable {
    public var id: UUID { track.id }
    public let track: Track
    public var matches: [URL]

    public init(track: Track, matches: [URL] = []) {
        self.track = track
        self.matches = matches
    }
}
