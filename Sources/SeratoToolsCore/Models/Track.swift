import Foundation

public struct Track: Identifiable, Hashable, Sendable {
    public let id: UUID
    public var fileURL: URL
    public var title: String
    public var artist: String
    public var bpm: Double?
    public var key: String?

    public init(
        id: UUID = UUID(),
        fileURL: URL,
        title: String,
        artist: String,
        bpm: Double? = nil,
        key: String? = nil
    ) {
        self.id = id
        self.fileURL = fileURL
        self.title = title
        self.artist = artist
        self.bpm = bpm
        self.key = key
    }
}
