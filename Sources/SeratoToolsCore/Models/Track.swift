import Foundation

/// A single track entry (`otrk` record) from Serato's `database V2` file.
public struct Track: Identifiable, Hashable, Sendable {
    public let id: UUID

    /// The path exactly as Serato stored it in the `pfil` field: relative to
    /// the filesystem root ("/") for tracks on the boot volume, or relative
    /// to the volume's mount point for tracks on an external drive. Kept
    /// verbatim (not just derived from `fileURL`) so a path-rewrite can
    /// match the original bytes exactly.
    public var seratoStoredPath: String

    /// `seratoStoredPath` resolved to an absolute file URL, using the
    /// library's root directory (see `SeratoLibraryLocator.rootDirectory`).
    public var fileURL: URL

    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var comment: String
    public var grouping: String
    public var label: String
    public var year: Int?
    public var duration: TimeInterval?
    public var bitrate: String?
    public var sampleRate: String?
    public var bpm: Double?
    public var key: String?
    public var isBeatgridLocked: Bool
    public var isMissing: Bool
    public var dateAdded: Date?

    public init(
        id: UUID = UUID(),
        seratoStoredPath: String,
        fileURL: URL,
        title: String = "",
        artist: String = "",
        album: String = "",
        genre: String = "",
        comment: String = "",
        grouping: String = "",
        label: String = "",
        year: Int? = nil,
        duration: TimeInterval? = nil,
        bitrate: String? = nil,
        sampleRate: String? = nil,
        bpm: Double? = nil,
        key: String? = nil,
        isBeatgridLocked: Bool = false,
        isMissing: Bool = false,
        dateAdded: Date? = nil
    ) {
        self.id = id
        self.seratoStoredPath = seratoStoredPath
        self.fileURL = fileURL
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.comment = comment
        self.grouping = grouping
        self.label = label
        self.year = year
        self.duration = duration
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.bpm = bpm
        self.key = key
        self.isBeatgridLocked = isBeatgridLocked
        self.isMissing = isMissing
        self.dateAdded = dateAdded
    }
}
