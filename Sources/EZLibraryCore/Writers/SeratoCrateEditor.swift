import Foundation

/// Safe crate file mutations (create/update track membership) that never touch
/// audio files themselves.
public enum SeratoCrateEditor {
    public enum EditError: Error {
        case seratoIsRunning
        case missingCrateFileURL
    }

    /// Creates a new crate file under `destinationFileURL`.
    public static func createCrate(
        at destinationFileURL: URL,
        trackPaths: [String] = []
    ) throws {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw EditError.seratoIsRunning
        }

        let uniqueTrackPaths = uniquedPreservingOrder(trackPaths)
        let data = SeratoCrateWriter.makeCrateData(trackPaths: uniqueTrackPaths)
        try AtomicFileWriter.write(data, to: destinationFileURL)
    }

    /// Rewrites one existing crate's track membership.
    @discardableResult
    public static func rewriteTrackPaths(
        in crate: Crate,
        to trackPaths: [String]
    ) throws -> Crate {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw EditError.seratoIsRunning
        }
        guard let fileURL = crate.fileURL else {
            throw EditError.missingCrateFileURL
        }

        if FileManager.default.fileExists(atPath: fileURL.path) {
            try SeratoBackupBeforeWrite.snapshot(of: fileURL)
        }

        let uniqueTrackPaths = uniquedPreservingOrder(trackPaths)
        let data = SeratoCrateWriter.makeCrateData(trackPaths: uniqueTrackPaths)
        try AtomicFileWriter.write(data, to: fileURL)

        var updated = crate
        updated.trackPaths = uniqueTrackPaths
        return updated
    }

    private static func uniquedPreservingOrder(_ trackPaths: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for path in trackPaths {
            if seen.insert(path).inserted {
                result.append(path)
            }
        }
        return result
    }
}
