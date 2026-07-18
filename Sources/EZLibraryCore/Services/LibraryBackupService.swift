import Foundation

public struct LibraryBackupResult: Sendable {
    public let backupRootURL: URL
    public let mode: LibraryBackupService.BackupMode
    public let copiedSeratoFolder: Bool
    public let copiedTrackCount: Int
    public let skippedTrackCount: Int
    public let copiedCrateCount: Int
    public let copiedByteCount: Int64
    public let note: String?
}

public struct LibraryBackupPreview: Sendable {
    public let trackCount: Int
    public let crateCount: Int
    public let estimatedByteCount: Int64
    public let crateName: String?
    public let mode: LibraryBackupService.BackupMode
    public let backupRootName: String
}

public enum LibraryBackupService {
    public enum BackupMode: String, Sendable, CaseIterable, Codable {
        case full
        case incremental
        case singleCrate

        public var title: String {
            switch self {
            case .full:
                return "Full backup"
            case .incremental:
                return "Incremental backup"
            case .singleCrate:
                return "Single-crate backup"
            }
        }

        public var detail: String {
            switch self {
            case .full:
                return "Copy the whole Serato folder and every track file into one timestamped backup."
            case .incremental:
                return "Copy the Serato folder and only track files that are not already in the latest backup."
            case .singleCrate:
                return "Package one crate file and the tracks it references."
            }
        }
    }

    public enum BackupError: Error, LocalizedError {
        case seratoIsRunning
        case noTracksAvailable
        case noCrateSelected
        case selectedCrateHasNoFile
        case selectedCrateNotFound
        case copyFailed(source: URL, destination: URL, underlying: Error)
        case manifestWriteFailed(URL, underlying: Error)

        public var errorDescription: String? {
            switch self {
            case .seratoIsRunning:
                return "Serato appears to be running. Close Serato before creating a backup."
            case .noTracksAvailable:
                return "No tracks are available to back up. Reload the library and try again."
            case .noCrateSelected:
                return "Choose a crate before running a single-crate backup."
            case .selectedCrateHasNoFile:
                return "The selected crate does not have a file on disk to package."
            case .selectedCrateNotFound:
                return "The selected crate could not be found in the current library."
            case let .copyFailed(source, destination, _):
                return "Could not copy \(source.lastPathComponent) to \(destination.deletingLastPathComponent().path)."
            case let .manifestWriteFailed(url, _):
                return "Could not write the backup manifest at \(url.path)."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .seratoIsRunning:
                return "Quit Serato DJ, then run the backup again."
            case .noTracksAvailable:
                return "Reload the library or choose a different library directory."
            case .noCrateSelected:
                return "Pick a crate from the list before backing up a single set."
            case .selectedCrateHasNoFile:
                return "Pick a crate that exists on disk, then try again."
            case .selectedCrateNotFound:
                return "Reload the library so the crate list matches the current library files."
            case .copyFailed:
                return "Check disk permissions and free space, then try again."
            case .manifestWriteFailed:
                return "Choose a destination you can write to and retry the backup."
            }
        }
    }

    private struct BackupManifest: Codable {
        let mode: BackupMode
        let createdAt: Date
        let copiedSeratoFolder: Bool
        let copiedTrackSourcePaths: [String]
        let copiedCrateSourcePaths: [String]
        let note: String?
    }

    private struct BackupContext {
        let backupRootURL: URL
        let previousManifest: BackupManifest?
        let note: String?
        let rootName: String
    }

    public static func preview(
        destinationFolderURL: URL,
        mode: BackupMode,
        tracks: [Track],
        crates: [Crate],
        selectedCrateID: UUID? = nil,
        libraryDirectory: URL,
        rootDirectory: URL,
        timestamp: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> LibraryBackupPreview {
        let context = try prepareContext(
            destinationFolderURL: destinationFolderURL,
            mode: mode,
            tracks: tracks,
            crates: crates,
            selectedCrateID: selectedCrateID,
            timestamp: timestamp,
            fileManager: fileManager
        )

        switch mode {
        case .full:
            let tracksToCopy = tracksToBackUp(tracks: tracks, mode: mode, previousManifest: context.previousManifest, fileManager: fileManager)
            let trackBytes = byteCount(of: tracksToCopy, fileManager: fileManager)
            let seratoBytes = itemByteSize(at: libraryDirectory, fileManager: fileManager) ?? 0
            return LibraryBackupPreview(
                trackCount: tracksToCopy.count,
                crateCount: crates.count,
                estimatedByteCount: trackBytes + seratoBytes,
                crateName: nil,
                mode: mode,
                backupRootName: context.rootName
            )
        case .incremental:
            let tracksToCopy = tracksToBackUp(tracks: tracks, mode: mode, previousManifest: context.previousManifest, fileManager: fileManager)
            let trackBytes = byteCount(of: tracksToCopy, fileManager: fileManager)
            let seratoBytes = itemByteSize(at: libraryDirectory, fileManager: fileManager) ?? 0
            return LibraryBackupPreview(
                trackCount: tracksToCopy.count,
                crateCount: crates.count,
                estimatedByteCount: trackBytes + seratoBytes,
                crateName: nil,
                mode: mode,
                backupRootName: context.rootName
            )
        case .singleCrate:
            let crate = try resolvedCrate(from: crates, selectedCrateID: selectedCrateID)
            let selectedTrackPaths = Set(crate.trackPaths)
            let selectedTracks = tracks.filter { selectedTrackPaths.contains($0.seratoStoredPath) }
            let crateBytes = itemByteSize(at: crate.fileURL ?? libraryDirectory, fileManager: fileManager) ?? 0
            return LibraryBackupPreview(
                trackCount: selectedTracks.count,
                crateCount: 1,
                estimatedByteCount: byteCount(of: selectedTracks, fileManager: fileManager) + crateBytes,
                crateName: crate.name.isEmpty ? crate.fileURL?.deletingPathExtension().lastPathComponent : crate.name,
                mode: mode,
                backupRootName: context.rootName
            )
        }
    }

    public static func backup(
        destinationFolderURL: URL,
        mode: BackupMode,
        tracks: [Track],
        crates: [Crate],
        selectedCrateID: UUID? = nil,
        libraryDirectory: URL,
        rootDirectory: URL,
        timestamp: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> LibraryBackupResult {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw BackupError.seratoIsRunning
        }

        let context = try prepareContext(
            destinationFolderURL: destinationFolderURL,
            mode: mode,
            tracks: tracks,
            crates: crates,
            selectedCrateID: selectedCrateID,
            timestamp: timestamp,
            fileManager: fileManager
        )

        try fileManager.createDirectory(at: context.backupRootURL, withIntermediateDirectories: true)

        let copiedTrackSourcePaths: [String]
        let copiedCrateSourcePaths: [String]
        let copiedSeratoFolder: Bool

        switch mode {
        case .full, .incremental:
            try copySeratoFolder(
                from: libraryDirectory,
                to: context.backupRootURL
                    .appendingPathComponent("Serato", isDirectory: true)
                    .appendingPathComponent(libraryDirectory.lastPathComponent, isDirectory: true),
                fileManager: fileManager
            )
            copiedSeratoFolder = true

            let tracksToCopy = tracksToBackUp(
                tracks: tracks,
                mode: mode,
                previousManifest: context.previousManifest,
                fileManager: fileManager
            )
            copiedTrackSourcePaths = try copyTracks(
                tracksToCopy,
                rootDirectory: rootDirectory,
                destinationRoot: context.backupRootURL.appendingPathComponent("Music", isDirectory: true),
                fileManager: fileManager
            )
            copiedCrateSourcePaths = []

        case .singleCrate:
            let crate = try resolvedCrate(from: crates, selectedCrateID: selectedCrateID)
            guard let crateFileURL = crate.fileURL else {
                throw BackupError.selectedCrateHasNoFile
            }

            copiedSeratoFolder = false
            copiedCrateSourcePaths = [crateFileURL.path]
            try copyCrateFile(
                crateFileURL,
                libraryDirectory: libraryDirectory,
                destinationRoot: context.backupRootURL.appendingPathComponent("Crates", isDirectory: true),
                fileManager: fileManager
            )

            let selectedTrackPaths = Set(crate.trackPaths)
            let selectedTracks = tracks.filter { selectedTrackPaths.contains($0.seratoStoredPath) }
            copiedTrackSourcePaths = try copyTracks(
                selectedTracks,
                rootDirectory: rootDirectory,
                destinationRoot: context.backupRootURL.appendingPathComponent("Tracks", isDirectory: true),
                fileManager: fileManager
            )
        }

        let manifest = BackupManifest(
            mode: mode,
            createdAt: timestamp,
            copiedSeratoFolder: copiedSeratoFolder,
            copiedTrackSourcePaths: copiedTrackSourcePaths,
            copiedCrateSourcePaths: copiedCrateSourcePaths,
            note: context.note
        )
        try writeManifest(manifest, to: context.backupRootURL, fileManager: fileManager)

        return LibraryBackupResult(
            backupRootURL: context.backupRootURL,
            mode: mode,
            copiedSeratoFolder: copiedSeratoFolder,
            copiedTrackCount: copiedTrackSourcePaths.count,
            skippedTrackCount: max(0, tracks.count - copiedTrackSourcePaths.count),
            copiedCrateCount: copiedCrateSourcePaths.count,
            copiedByteCount: byteCount(of: copiedTrackSourcePaths, fileManager: fileManager),
            note: context.note
        )
    }

    public static func latestBackupDate(
        destinationFolderURL: URL,
        fileManager: FileManager = .default
    ) -> Date? {
        let containerURL = destinationFolderURL.appendingPathComponent("SeratoBackups", isDirectory: true)
        guard let entries = try? fileManager.contentsOfDirectory(at: containerURL, includingPropertiesForKeys: nil) else {
            return nil
        }

        let backupDirectories = entries
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for directory in backupDirectories.reversed() {
            let manifestURL = directory.appendingPathComponent("backup-manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else {
                continue
            }
            return manifest.createdAt
        }

        return nil
    }

    private static func prepareContext(
        destinationFolderURL: URL,
        mode: BackupMode,
        tracks: [Track],
        crates: [Crate],
        selectedCrateID: UUID?,
        timestamp: Date,
        fileManager: FileManager
    ) throws -> BackupContext {
        let backupContainerURL = destinationFolderURL.appendingPathComponent("SeratoBackups", isDirectory: true)
        try fileManager.createDirectory(at: backupContainerURL, withIntermediateDirectories: true)

        let previousManifest = try latestBackupManifest(in: backupContainerURL, fileManager: fileManager)
        let rootName = backupRootName(
            mode: mode,
            crates: crates,
            selectedCrateID: selectedCrateID,
            timestamp: timestamp
        )
        let backupRootURL = uniqueBackupRootURL(
            backupContainerURL.appendingPathComponent(rootName, isDirectory: true),
            fileManager: fileManager
        )

        if mode == .full, tracks.isEmpty {
            throw BackupError.noTracksAvailable
        }

        if mode == .singleCrate {
            _ = try resolvedCrate(from: crates, selectedCrateID: selectedCrateID)
        }

        let note: String?
        if mode == .incremental, previousManifest == nil {
            note = "No previous backup was found, so this incremental backup included every available track."
        } else {
            note = nil
        }

        return BackupContext(
            backupRootURL: backupRootURL,
            previousManifest: previousManifest,
            note: note,
            rootName: rootName
        )
    }

    private static func latestBackupManifest(
        in backupContainerURL: URL,
        fileManager: FileManager
    ) throws -> BackupManifest? {
        guard let entries = try? fileManager.contentsOfDirectory(at: backupContainerURL, includingPropertiesForKeys: nil) else {
            return nil
        }

        let backupDirectories = entries
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }

        for directory in backupDirectories.reversed() {
            let manifestURL = directory.appendingPathComponent("backup-manifest.json")
            guard fileManager.fileExists(atPath: manifestURL.path),
                  let data = try? Data(contentsOf: manifestURL),
                  let manifest = try? JSONDecoder().decode(BackupManifest.self, from: data) else {
                continue
            }
            return manifest
        }

        return nil
    }

    private static func tracksToBackUp(
        tracks: [Track],
        mode: BackupMode,
        previousManifest: BackupManifest?,
        fileManager: FileManager
    ) -> [Track] {
        let existingPaths = Set(previousManifest?.copiedTrackSourcePaths ?? [])

        let filtered = tracks.filter { track in
            guard fileManager.fileExists(atPath: track.fileURL.path) else { return false }
            switch mode {
            case .full:
                return true
            case .incremental:
                return !existingPaths.contains(track.fileURL.path)
            case .singleCrate:
                return true
            }
        }

        var seen = Set<String>()
        return filtered.filter { seen.insert($0.fileURL.path).inserted }
    }

    private static func resolvedCrate(from crates: [Crate], selectedCrateID: UUID?) throws -> Crate {
        guard let selectedCrateID else {
            throw BackupError.noCrateSelected
        }
        guard let crate = crates.first(where: { $0.id == selectedCrateID }) else {
            throw BackupError.selectedCrateNotFound
        }
        return crate
    }

    private static func copySeratoFolder(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            if fileManager.fileExists(atPath: destinationURL.path) {
                try fileManager.removeItem(at: destinationURL)
            }
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw BackupError.copyFailed(source: sourceURL, destination: destinationURL, underlying: error)
        }
    }

    private static func copyCrateFile(
        _ sourceURL: URL,
        libraryDirectory: URL,
        destinationRoot: URL,
        fileManager: FileManager
    ) throws {
        let destinationURL = destinationRoot.appendingPathComponent(relativePath(from: sourceURL, baseURL: libraryDirectory))
        try copyItem(sourceURL, to: destinationURL, fileManager: fileManager)
    }

    private static func copyTracks(
        _ tracks: [Track],
        rootDirectory: URL,
        destinationRoot: URL,
        fileManager: FileManager
    ) throws -> [String] {
        var copiedPaths: [String] = []
        var reservedDestinations = Set<String>()

        for track in tracks {
            let destinationURL = uniquedDestinationURL(
                destinationRoot.appendingPathComponent(relativePath(from: track.fileURL, baseURL: rootDirectory)),
                reservedDestinations: &reservedDestinations,
                fileManager: fileManager
            )
            try copyItem(track.fileURL, to: destinationURL, fileManager: fileManager)
            copiedPaths.append(track.fileURL.path)
        }

        return copiedPaths
    }

    private static func itemByteSize(at url: URL, fileManager: FileManager) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private static func byteCount(of tracks: [Track], fileManager: FileManager) -> Int64 {
        tracks.reduce(0) { partialResult, track in
            partialResult + (itemByteSize(at: track.fileURL, fileManager: fileManager) ?? 0)
        }
    }

    private static func byteCount(of copiedTrackPaths: [String], fileManager: FileManager) -> Int64 {
        copiedTrackPaths.reduce(0) { partialResult, path in
            let url = URL(fileURLWithPath: path)
            return partialResult + (itemByteSize(at: url, fileManager: fileManager) ?? 0)
        }
    }

    private static func copyItem(
        _ sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        try fileManager.createDirectory(at: destinationURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw BackupError.copyFailed(source: sourceURL, destination: destinationURL, underlying: error)
        }
    }

    private static func writeManifest(
        _ manifest: BackupManifest,
        to backupRootURL: URL,
        fileManager: FileManager
    ) throws {
        let manifestURL = backupRootURL.appendingPathComponent("backup-manifest.json")
        do {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            encoder.dateEncodingStrategy = .iso8601
            let data = try encoder.encode(manifest)
            try fileManager.createDirectory(at: manifestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: manifestURL, options: [.atomic])
        } catch {
            throw BackupError.manifestWriteFailed(manifestURL, underlying: error)
        }
    }

    private static func timestampString(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        return formatter.string(from: date)
    }

    private static func backupRootName(mode: BackupMode, crates: [Crate], selectedCrateID: UUID?, timestamp: Date) -> String {
        let stamped = timestampString(from: timestamp)
        switch mode {
        case .singleCrate:
            let crateName = crates.first(where: { $0.id == selectedCrateID })?.name
                ?? crates.first(where: { $0.id == selectedCrateID })?.fileURL?.deletingPathExtension().lastPathComponent
                ?? "Crate"
            return "\(stamped) - \(sanitizedFolderName(crateName))"
        case .full:
            return stamped
        case .incremental:
            return "\(stamped) - Incremental"
        }
    }

    private static func sanitizedFolderName(_ name: String) -> String {
        let invalid = CharacterSet(charactersIn: "/:")
        return name.components(separatedBy: invalid).joined(separator: "-")
    }

    private static func relativePath(from fileURL: URL, baseURL: URL) -> String {
        let baseComponents = baseURL.standardizedFileURL.pathComponents
        var fileComponents = fileURL.standardizedFileURL.pathComponents
        if fileComponents.starts(with: baseComponents) {
            fileComponents.removeFirst(baseComponents.count)
        }
        if fileComponents.isEmpty {
            return fileURL.lastPathComponent
        }
        return NSString.path(withComponents: fileComponents)
    }

    private static func uniqueBackupRootURL(_ url: URL, fileManager: FileManager) -> URL {
        var candidate = url.standardizedFileURL
        var suffix = 2

        while fileManager.fileExists(atPath: candidate.path) {
            candidate = url.deletingLastPathComponent().appendingPathComponent("\(url.lastPathComponent)-\(suffix)", isDirectory: true)
            suffix += 1
        }

        return candidate
    }

    private static func uniquedDestinationURL(
        _ destinationURL: URL,
        reservedDestinations: inout Set<String>,
        fileManager: FileManager
    ) -> URL {
        var candidate = destinationURL.standardizedFileURL
        var suffix = 2

        while reservedDestinations.contains(candidate.path) || fileManager.fileExists(atPath: candidate.path) {
            let directory = destinationURL.deletingLastPathComponent()
            let baseName = destinationURL.deletingPathExtension().lastPathComponent
            let pathExtension = destinationURL.pathExtension
            let uniqueName = pathExtension.isEmpty
                ? "\(baseName) \(suffix)"
                : "\(baseName) \(suffix).\(pathExtension)"
            candidate = directory.appendingPathComponent(uniqueName)
            suffix += 1
        }

        reservedDestinations.insert(candidate.path)
        return candidate
    }
}