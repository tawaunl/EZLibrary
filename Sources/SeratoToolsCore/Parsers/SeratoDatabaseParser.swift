import Foundation

/// Parses Serato's binary `database V2` track database format.
///
/// Format reference: a flat sequence of tagged chunks (4-byte ASCII tag +
/// 4-byte big-endian length + payload). Not yet implemented — this is a
/// placeholder so the app skeleton compiles end to end.
public enum SeratoDatabaseParser {
    public enum ParserError: Error {
        case fileNotFound(URL)
        case malformedData(String)
    }

    public static func parseTracks(at fileURL: URL) throws -> [Track] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ParserError.fileNotFound(fileURL)
        }
        // TODO: implement chunk parsing (otrk/ttyp/pfil/tsng/tart/tbpm/tkey...)
        return []
    }
}
