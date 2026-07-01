import Foundation

/// Parses a single Serato `.crate` file: a `vrsn` header, `ovct`
/// column-view metadata, and one `otrk` chunk per track containing a
/// nested `ptrk` (track path) field.
///
/// Field tags cross-checked against Mixxx's open-source Serato crate
/// reader (`src/library/serato/seratofeature.cpp`).
public enum SeratoCrateParser {
    public enum ParserError: Error {
        case fileNotFound(URL)
    }

    public static func parseCrate(at fileURL: URL) throws -> Crate {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw ParserError.fileNotFound(fileURL)
        }
        let data = try Data(contentsOf: fileURL)
        let baseName = fileURL.deletingPathExtension().lastPathComponent
        return Crate(
            pathComponents: Crate.pathComponents(forCrateFileNamed: baseName),
            trackPaths: trackPaths(from: data),
            fileURL: fileURL
        )
    }

    public static func trackPaths(from data: Data) -> [String] {
        SeratoChunkCodec.readChunks(from: data)
            .filter { $0.tag == "otrk" }
            .compactMap { trackPath(from: $0.payload) }
    }

    private static func trackPath(from otrkPayload: Data) -> String? {
        SeratoChunkCodec.readChunks(from: otrkPayload)
            .first(where: { $0.tag == "ptrk" })
            .map { SeratoChunkCodec.decodeUTF16BEString($0.payload) }
    }
}
