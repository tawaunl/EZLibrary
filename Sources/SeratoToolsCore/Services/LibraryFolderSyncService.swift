import Foundation

public enum LibraryFolderSyncService {
    public struct SyncResult: Sendable {
        public let scannedAudioFiles: Int
        public let insertedTracks: Int
        public let alreadyPresentTracks: Int

        public init(scannedAudioFiles: Int, insertedTracks: Int, alreadyPresentTracks: Int) {
            self.scannedAudioFiles = scannedAudioFiles
            self.insertedTracks = insertedTracks
            self.alreadyPresentTracks = alreadyPresentTracks
        }
    }

    public enum SyncError: LocalizedError {
        case folderNotFound(URL)
        case noSupportedAudioFiles(URL)
        case databaseNotFound(URL)

        public var errorDescription: String? {
            switch self {
            case let .folderNotFound(folderURL):
                return "Folder not found: \(folderURL.path)."
            case let .noSupportedAudioFiles(folderURL):
                return "No supported audio files were found in \(folderURL.path)."
            case let .databaseNotFound(databaseURL):
                return "Serato database V2 was not found at \(databaseURL.path)."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .folderNotFound:
                return "Choose a valid folder path and try syncing again."
            case .noSupportedAudioFiles:
                return "Add supported formats like mp3, m4a, aac, wav, aif, aiff, flac, alac, or ogg first."
            case .databaseNotFound:
                return "Open Serato once to initialize the library, then retry."
            }
        }
    }

    public static func syncAudioFolder(
        _ folderURL: URL,
        databaseFileURL: URL,
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> SyncResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SyncError.folderNotFound(folderURL)
        }

        guard fileManager.fileExists(atPath: databaseFileURL.path) else {
            throw SyncError.databaseNotFound(databaseFileURL)
        }

        let audioFiles = AddMusicImportService.discoverAudioFiles(from: [folderURL], fileManager: fileManager)
        guard !audioFiles.isEmpty else {
            throw SyncError.noSupportedAudioFiles(folderURL)
        }

        try SeratoBackupBeforeWrite.snapshot(of: databaseFileURL)
        var data = try Data(contentsOf: databaseFileURL)

        var inserted = 0
        var alreadyPresent = 0

        for fileURL in audioFiles {
            let storedPath = SeratoLibraryLocator.seratoStoredPath(for: fileURL, rootDirectory: rootDirectory)
            let ensured = SeratoDatabaseWriter.ensuringTrackExists(forStoredPath: storedPath, in: data)
            data = ensured.data
            if ensured.didInsert {
                inserted += 1
            } else {
                alreadyPresent += 1
            }
        }

        if inserted > 0 {
            try AtomicFileWriter.write(data, to: databaseFileURL)
        }

        return SyncResult(
            scannedAudioFiles: audioFiles.count,
            insertedTracks: inserted,
            alreadyPresentTracks: alreadyPresent
        )
    }
}