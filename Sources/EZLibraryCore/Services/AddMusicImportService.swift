import Foundation

public enum AddMusicImportService {
    public enum TransferMode: String, CaseIterable, Sendable {
        case move
        case copy
    }

    public enum ImportError: Error, LocalizedError {
        case noInputSelected
        case noSupportedAudioFiles
        case missingCrateFileURL
        case fileTransferFailed(URL, URL, mode: TransferMode, underlying: Error)
        case rollbackFailed(URL, URL)

        public var errorDescription: String? {
            switch self {
            case .noInputSelected:
                return "Choose at least one file or folder to import."
            case .noSupportedAudioFiles:
                return "No supported audio files were found in the selected items."
            case .missingCrateFileURL:
                return "The selected crate is missing its file path on disk."
            case let .fileTransferFailed(sourceURL, destinationURL, mode, _):
                let verb = mode == .copy ? "copy" : "move"
                return "Couldn't \(verb) \(sourceURL.lastPathComponent) into \(destinationURL.deletingLastPathComponent().path)."
            case let .rollbackFailed(sourceURL, destinationURL):
                return "Import failed and rollback could not restore \(destinationURL.lastPathComponent) back to \(sourceURL.deletingLastPathComponent().path)."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .noInputSelected:
                return "Pick files or folders, then import again."
            case .noSupportedAudioFiles:
                return "Include supported formats like mp3, m4a, aac, wav, aif, aiff, flac, alac, or ogg."
            case .missingCrateFileURL:
                return "Reload the library and select the crate again."
            case .fileTransferFailed:
                return "Check disk permissions and free space, then retry."
            case .rollbackFailed:
                return "Review the destination folder and move any partial files back before retrying."
            }
        }
    }

    public struct ImportResult: Sendable {
        public let importedTrackCount: Int
        public let crateFileURL: URL
        public let crateName: String
        public let destinationFolderURL: URL
        public let transferMode: TransferMode
    }

    public struct ImportFilesResult: Sendable {
        public let importedTrackCount: Int
        public let destinationFolderURL: URL
        public let transferMode: TransferMode
        public let importedFileURLs: [URL]
    }

    public struct CrateCreationResult: Sendable {
        public let crateFileURL: URL
        public let crateName: String
        public let trackCount: Int
    }

    public enum CrateAssignment: Sendable {
        case dated(prefix: String)
        case named(String)
        case existing(Crate)
    }

    // Common DJ-library audio formats.
    public static let supportedAudioExtensions: Set<String> = [
        "mp3", "m4a", "aac", "wav", "aif", "aiff", "flac", "alac", "ogg"
    ]

    public static func discoverAudioFiles(from inputURLs: [URL], fileManager: FileManager = .default) -> [URL] {
        var discovered: [URL] = []
        var seen = Set<String>()

        for inputURL in inputURLs {
            let standardized = inputURL.standardizedFileURL
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: standardized.path, isDirectory: &isDirectory) else {
                continue
            }

            if !isDirectory.boolValue {
                guard isSupportedAudioFile(standardized) else { continue }
                if seen.insert(standardized.path).inserted {
                    discovered.append(standardized)
                }
                continue
            }

            guard let enumerator = fileManager.enumerator(
                at: standardized,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else {
                continue
            }

            for case let item as URL in enumerator {
                guard isSupportedAudioFile(item) else { continue }
                let fileURL = item.standardizedFileURL
                if seen.insert(fileURL.path).inserted {
                    discovered.append(fileURL)
                }
            }
        }

        return discovered.sorted {
            $0.path.localizedStandardCompare($1.path) == .orderedAscending
        }
    }

    public static func importIntoDatedCrate(
        inputURLs: [URL],
        destinationFolderURL: URL,
        crateNamePrefix: String,
        transferMode: TransferMode,
        subcratesDirectory: URL,
        rootDirectory: URL,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> ImportResult {
        let imported = try importAudioFiles(
            inputURLs: inputURLs,
            destinationFolderURL: destinationFolderURL,
            transferMode: transferMode,
            fileManager: fileManager
        )

        let crateResult = try createDatedCrate(
            forAudioFiles: imported.importedFileURLs,
            crateNamePrefix: crateNamePrefix,
            subcratesDirectory: subcratesDirectory,
            rootDirectory: rootDirectory,
            date: date,
            fileManager: fileManager
        )

        return ImportResult(
            importedTrackCount: imported.importedTrackCount,
            crateFileURL: crateResult.crateFileURL,
            crateName: crateResult.crateName,
            destinationFolderURL: imported.destinationFolderURL,
            transferMode: imported.transferMode
        )
    }

    public static func importAudioFiles(
        inputURLs: [URL],
        destinationFolderURL: URL,
        transferMode: TransferMode,
        fileManager: FileManager = .default
    ) throws -> ImportFilesResult {
        guard !inputURLs.isEmpty else {
            throw ImportError.noInputSelected
        }

        let sourceFiles = discoverAudioFiles(from: inputURLs, fileManager: fileManager)
        guard !sourceFiles.isEmpty else {
            throw ImportError.noSupportedAudioFiles
        }

        let importFolderURL = destinationFolderURL.standardizedFileURL
        try fileManager.createDirectory(at: importFolderURL, withIntermediateDirectories: true)

        let transferPairs = plannedTransferPairs(
            for: sourceFiles,
            destinationDirectory: importFolderURL,
            fileManager: fileManager
        )
        let executedPairs = try transferFiles(transferPairs, mode: transferMode, fileManager: fileManager)

        return ImportFilesResult(
            importedTrackCount: executedPairs.count,
            destinationFolderURL: importFolderURL,
            transferMode: transferMode,
            importedFileURLs: executedPairs.map(\.destinationURL)
        )
    }

    public static func createDatedCrate(
        forAudioFiles audioFiles: [URL],
        crateNamePrefix: String,
        subcratesDirectory: URL,
        rootDirectory: URL,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> CrateCreationResult {
        guard !audioFiles.isEmpty else {
            throw ImportError.noSupportedAudioFiles
        }

        let existingFiles = audioFiles
            .map(\.standardizedFileURL)
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !existingFiles.isEmpty else {
            throw ImportError.noSupportedAudioFiles
        }

        let storedPaths = existingFiles.map {
            SeratoLibraryLocator.seratoStoredPath(for: $0, rootDirectory: rootDirectory)
        }
        let crateName = uniqueCrateName(prefix: crateNamePrefix, date: date, subcratesDirectory: subcratesDirectory, fileManager: fileManager)
        let crateURL = subcratesDirectory.appendingPathComponent(crateName).appendingPathExtension("crate")
        let crateData = SeratoCrateWriter.makeCrateData(trackPaths: storedPaths)
        try AtomicFileWriter.write(crateData, to: crateURL)

        return CrateCreationResult(
            crateFileURL: crateURL,
            crateName: crateName,
            trackCount: storedPaths.count
        )
    }

    public static func createNamedCrate(
        forAudioFiles audioFiles: [URL],
        crateName: String,
        subcratesDirectory: URL,
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> CrateCreationResult {
        guard !audioFiles.isEmpty else {
            throw ImportError.noSupportedAudioFiles
        }

        let existingFiles = audioFiles
            .map(\.standardizedFileURL)
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !existingFiles.isEmpty else {
            throw ImportError.noSupportedAudioFiles
        }

        let storedPaths = existingFiles.map {
            SeratoLibraryLocator.seratoStoredPath(for: $0, rootDirectory: rootDirectory)
        }
        let uniqueName = uniqueNamedCrateName(baseName: crateName, subcratesDirectory: subcratesDirectory, fileManager: fileManager)
        let crateURL = subcratesDirectory.appendingPathComponent(uniqueName).appendingPathExtension("crate")
        let crateData = SeratoCrateWriter.makeCrateData(trackPaths: storedPaths)
        try AtomicFileWriter.write(crateData, to: crateURL)

        return CrateCreationResult(
            crateFileURL: crateURL,
            crateName: uniqueName,
            trackCount: storedPaths.count
        )
    }

    public static func appendAudioFiles(
        _ audioFiles: [URL],
        toExistingCrate crate: Crate,
        rootDirectory: URL,
        fileManager: FileManager = .default
    ) throws -> CrateCreationResult {
        guard let crateURL = crate.fileURL else {
            throw ImportError.missingCrateFileURL
        }

        let existingFiles = audioFiles
            .map(\.standardizedFileURL)
            .filter { fileManager.fileExists(atPath: $0.path) }
        guard !existingFiles.isEmpty else {
            throw ImportError.noSupportedAudioFiles
        }

        let newStoredPaths = existingFiles.map {
            SeratoLibraryLocator.seratoStoredPath(for: $0, rootDirectory: rootDirectory)
        }

        let mergedTrackPaths = uniquePreservingOrder(crate.trackPaths + newStoredPaths)

        if fileManager.fileExists(atPath: crateURL.path) {
            try SeratoBackupBeforeWrite.snapshot(of: crateURL)
        }

        let data = SeratoCrateWriter.makeCrateData(trackPaths: mergedTrackPaths)
        try AtomicFileWriter.write(data, to: crateURL)

        return CrateCreationResult(
            crateFileURL: crateURL,
            crateName: crate.name,
            trackCount: newStoredPaths.count
        )
    }

    public static func assignAudioFiles(
        _ audioFiles: [URL],
        assignments: [CrateAssignment],
        subcratesDirectory: URL,
        rootDirectory: URL,
        date: Date = Date(),
        fileManager: FileManager = .default
    ) throws -> [CrateCreationResult] {
        var results: [CrateCreationResult] = []
        var processedExistingCrates = Set<String>()

        for assignment in assignments {
            switch assignment {
            case let .dated(prefix):
                let result = try createDatedCrate(
                    forAudioFiles: audioFiles,
                    crateNamePrefix: prefix,
                    subcratesDirectory: subcratesDirectory,
                    rootDirectory: rootDirectory,
                    date: date,
                    fileManager: fileManager
                )
                results.append(result)

            case let .named(name):
                let result = try createNamedCrate(
                    forAudioFiles: audioFiles,
                    crateName: name,
                    subcratesDirectory: subcratesDirectory,
                    rootDirectory: rootDirectory,
                    fileManager: fileManager
                )
                results.append(result)

            case let .existing(crate):
                let crateKey = existingCrateKey(crate)
                guard processedExistingCrates.insert(crateKey).inserted else {
                    continue
                }

                let result = try appendAudioFiles(
                    audioFiles,
                    toExistingCrate: crate,
                    rootDirectory: rootDirectory,
                    fileManager: fileManager
                )
                results.append(result)
            }
        }

        return results
    }

    private static func isSupportedAudioFile(_ url: URL) -> Bool {
        supportedAudioExtensions.contains(url.pathExtension.lowercased())
    }

    private static func existingCrateKey(_ crate: Crate) -> String {
        if let fileURL = crate.fileURL {
            return fileURL.standardizedFileURL.path
        }
        return Crate.fileBaseName(forPathComponents: crate.pathComponents)
    }

    private static func datedName(prefix: String, date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd"
        let normalizedPrefix = prefix.trimmingCharacters(in: .whitespacesAndNewlines)
        let safePrefix = normalizedPrefix.isEmpty ? "New Music" : normalizedPrefix
        return "\(safePrefix) \(formatter.string(from: date))"
    }

    private static func uniqueCrateName(
        prefix: String,
        date: Date,
        subcratesDirectory: URL,
        fileManager: FileManager
    ) -> String {
        let base = datedName(prefix: prefix, date: date)
        return uniqueCrateName(base: base, subcratesDirectory: subcratesDirectory, fileManager: fileManager)
    }

    private static func uniqueNamedCrateName(
        baseName: String,
        subcratesDirectory: URL,
        fileManager: FileManager
    ) -> String {
        let normalizedBase = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        let safeBase = normalizedBase.isEmpty ? "New Music" : normalizedBase
        return uniqueCrateName(base: safeBase, subcratesDirectory: subcratesDirectory, fileManager: fileManager)
    }

    private static func uniqueCrateName(
        base: String,
        subcratesDirectory: URL,
        fileManager: FileManager
    ) -> String {
        var candidate = base
        var suffix = 2

        while fileManager.fileExists(atPath: subcratesDirectory.appendingPathComponent(candidate).appendingPathExtension("crate").path) {
            candidate = "\(base) (\(suffix))"
            suffix += 1
        }
        return candidate
    }

    private static func plannedTransferPairs(
        for sourceFiles: [URL],
        destinationDirectory: URL,
        fileManager: FileManager
    ) -> [(sourceURL: URL, destinationURL: URL)] {
        var reservedDestinations = Set<String>()
        return sourceFiles.map { sourceURL in
            let destination = uniquedDestinationURL(
                destinationDirectory.appendingPathComponent(sourceURL.lastPathComponent),
                reservedDestinations: &reservedDestinations,
                fileManager: fileManager
            )
            return (sourceURL, destination)
        }
    }

    private static func transferFiles(
        _ pairs: [(sourceURL: URL, destinationURL: URL)],
        mode: TransferMode,
        fileManager: FileManager
    ) throws -> [(sourceURL: URL, destinationURL: URL)] {
        var executedPairs: [(sourceURL: URL, destinationURL: URL)] = []

        do {
            for pair in pairs {
                let destinationDirectory = pair.destinationURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                do {
                    switch mode {
                    case .move:
                        try fileManager.moveItem(at: pair.sourceURL, to: pair.destinationURL)
                    case .copy:
                        try fileManager.copyItem(at: pair.sourceURL, to: pair.destinationURL)
                    }
                } catch {
                    throw ImportError.fileTransferFailed(pair.sourceURL, pair.destinationURL, mode: mode, underlying: error)
                }
                executedPairs.append(pair)
            }
            return executedPairs
        } catch {
            try rollbackTransfers(executedPairs, mode: mode, fileManager: fileManager)
            throw error
        }
    }

    private static func rollbackTransfers(
        _ executedPairs: [(sourceURL: URL, destinationURL: URL)],
        mode: TransferMode,
        fileManager: FileManager
    ) throws {
        for pair in executedPairs.reversed() {
            do {
                guard fileManager.fileExists(atPath: pair.destinationURL.path) else {
                    continue
                }

                switch mode {
                case .move:
                    let sourceDirectory = pair.sourceURL.deletingLastPathComponent()
                    try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
                    try fileManager.moveItem(at: pair.destinationURL, to: pair.sourceURL)
                case .copy:
                    try fileManager.removeItem(at: pair.destinationURL)
                }
            } catch {
                throw ImportError.rollbackFailed(pair.sourceURL, pair.destinationURL)
            }
        }
    }

    private static func uniquedDestinationURL(
        _ destinationURL: URL,
        reservedDestinations: inout Set<String>,
        fileManager: FileManager
    ) -> URL {
        var candidate = destinationURL
        let pathExtension = candidate.pathExtension
        let baseName = candidate.deletingPathExtension().lastPathComponent
        var suffix = 2

        func candidatePath(_ url: URL) -> String {
            url.standardizedFileURL.path
        }

        while reservedDestinations.contains(candidatePath(candidate)) || fileManager.fileExists(atPath: candidate.path) {
            let indexedName = "\(baseName) (\(suffix))"
            var next = candidate.deletingLastPathComponent().appendingPathComponent(indexedName)
            if !pathExtension.isEmpty {
                next.appendPathExtension(pathExtension)
            }
            candidate = next
            suffix += 1
        }

        reservedDestinations.insert(candidatePath(candidate))
        return candidate
    }

    private static func uniquePreservingOrder(_ values: [String]) -> [String] {
        var seen = Set<String>()
        var output: [String] = []
        for value in values {
            if seen.insert(value).inserted {
                output.append(value)
            }
        }
        return output
    }
}