import Foundation

/// Reads Serato's per-track play count.
///
/// Serato does not store the play count in the `database V2` file — it writes
/// it into the audio file's ID3 tag as a user-defined text frame
/// (`TXXX` with the description `SERATO_PLAYCOUNT`). Only the ID3 tag at the
/// start of the file is read (not the whole file), so this stays cheap enough
/// to run across a large library in the background.
public enum SeratoPlayCountReader {
    /// Descriptions to try, in priority order. `SERATO_PLAYCOUNT` is Serato's
    /// own frame; the `FMPS_*` variants are the cross-application fallbacks
    /// some tools write.
    private static let playCountDescriptions = ["SERATO_PLAYCOUNT", "FMPS_PLAYCOUNT", "FMPS_Playcount"]

    /// Returns the play count stored in the file's ID3 tag, or `nil` when the
    /// file is unsupported, has no ID3 tag, or carries no play-count frame.
    public static func playCount(forFileAt url: URL) -> Int? {
        guard url.pathExtension.lowercased() == "mp3" else { return nil }
        guard let tag = readID3TagBytes(at: url) else { return nil }

        for description in playCountDescriptions {
            guard let value = ID3ArtworkCodec.userTextValue(fromID3TagBytes: tag, description: description) else {
                continue
            }
            if let count = parseCount(value) {
                return count
            }
        }
        return nil
    }

    /// Reads just the leading ID3v2 tag (header + declared size) rather than
    /// the entire file, so scanning thousands of tracks stays fast.
    private static func readID3TagBytes(at url: URL) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }

        guard let headerData = try? handle.read(upToCount: 10), headerData.count == 10 else { return nil }
        let header = [UInt8](headerData)
        guard header[0] == 0x49, header[1] == 0x44, header[2] == 0x33 else { return nil } // "ID3"

        let size = decodeSyncSafe(Array(header[6..<10]))
        guard size > 0 else { return headerData }
        guard let body = try? handle.read(upToCount: size) else { return nil }

        var data = Data(headerData)
        data.append(body)
        return data
    }

    private static func parseCount(_ value: String) -> Int? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        // Some tools store a decimal ("5.0"); accept the integer part.
        if let intValue = Int(trimmed) {
            return max(0, intValue)
        }
        if let doubleValue = Double(trimmed) {
            return max(0, Int(doubleValue))
        }
        return nil
    }

    private static func decodeSyncSafe(_ bytes: [UInt8]) -> Int {
        guard bytes.count == 4 else { return 0 }
        return (Int(bytes[0] & 0x7F) << 21)
            | (Int(bytes[1] & 0x7F) << 14)
            | (Int(bytes[2] & 0x7F) << 7)
            | Int(bytes[3] & 0x7F)
    }
}
