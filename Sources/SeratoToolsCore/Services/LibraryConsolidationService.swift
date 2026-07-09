import Foundation

public struct LibraryConsolidationPreview: Sendable {
    public struct SourceGroup: Identifiable, Hashable, Sendable {
        public let id: String
        public let title: String
        public let trackCount: Int
        public let examplePath: String
        public let totalBytes: Int64
    }

    public struct Move: Identifiable, Hashable, Sendable {
        public let id: String
        public let originalStoredPath: String
        public let sourceURL: URL
        public let destinationURL: URL
        public let sourceGroupID: String
        public let sourceGroupTitle: String
        public let displayName: String
    }

    public let destinationFolderURL: URL
    public let moves: [Move]
    public let sourceGroups: [SourceGroup]
    public let skippedMissingCount: Int
    public let skippedAlreadyConsolidatedCount: Int
    public let skippedDuplicatePathCount: Int
    public let totalExistingBytes: Int64
    public let queuedTransferBytes: Int64
    public let alreadyConsolidatedBytes: Int64

    public var totalMoves: Int {
        moves.count
    }
}

/// Plans and executes a whole-library move into one central folder while
/// keeping Serato's database and crate references aligned with the new
/// audio-file locations.
public enum LibraryConsolidationService {
    public enum FileTransferMode: String, Sendable, CaseIterable {
        case move
        case copy
    }

    public enum ConsolidationError: Error, LocalizedError {
        case seratoIsRunning
        case noTracksToMove
        case fileTransferFailed(URL, URL, mode: FileTransferMode, underlying: Error)
        case rollbackFailed(URL, URL)

        public var errorDescription: String? {
            switch self {
            case .seratoIsRunning:
                return "Serato appears to be running. Close Serato before consolidating the library."
            case .noTracksToMove:
                return "No track files need to be moved into the selected destination folder."
            case let .fileTransferFailed(sourceURL, destinationURL, mode, _):
                let verb = mode == .copy ? "copy" : "move"
                return "Couldn't \(verb) \(sourceURL.lastPathComponent) into \(destinationURL.deletingLastPathComponent().path)."
            case let .rollbackFailed(sourceURL, destinationURL):
                return "A file move failed and rollback could not restore \(destinationURL.lastPathComponent) to \(sourceURL.deletingLastPathComponent().path)."
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .seratoIsRunning:
                return "Quit Serato DJ, then run the consolidation again."
            case .noTracksToMove:
                return "Choose a different destination folder or reload the library if you expected tracks to move."
            case .fileTransferFailed:
                return "Check disk permissions and free space, then try again. No Serato paths were rewritten yet."
            case .rollbackFailed:
                return "Review the destination folder and move any partially moved files back before retrying."
            }
        }
    }

    public struct ConsolidationResult: Sendable {
        public let processedTrackCount: Int
        public let updatedCrateCount: Int
        public let destinationFolderURL: URL
        public let mode: FileTransferMode
    }

    public static func preview(
        tracks: [Track],
        destinationFolderURL: URL,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        fileManager: FileManager = .default
    ) -> LibraryConsolidationPreview {
        let destinationRoot = destinationFolderURL.standardizedFileURL
        var moves: [LibraryConsolidationPreview.Move] = []
        var groupCounts: [String: Int] = [:]
        var groupTitles: [String: String] = [:]
        var groupPaths: [String: String] = [:]
        var reservedDestinations = Set<String>()
        var seenStoredPaths = Set<String>()
        var skippedMissingCount = 0
        var skippedAlreadyConsolidatedCount = 0
        var skippedDuplicatePathCount = 0
        var totalExistingBytes: Int64 = 0
        var queuedTransferBytes: Int64 = 0
        var alreadyConsolidatedBytes: Int64 = 0
        var groupBytes: [String: Int64] = [:]

        for track in tracks.sorted(by: { $0.fileURL.path.localizedStandardCompare($1.fileURL.path) == .orderedAscending }) {
            guard seenStoredPaths.insert(track.seratoStoredPath).inserted else {
                skippedDuplicatePathCount += 1
                continue
            }

            let sourceURL = track.fileURL.standardizedFileURL
            guard fileManager.fileExists(atPath: sourceURL.path) else {
                skippedMissingCount += 1
                continue
            }

            let fileSize = fileSizeOfItem(at: sourceURL, fileManager: fileManager) ?? 0
            totalExistingBytes += fileSize

            if isInsideDestination(sourceURL: sourceURL, destinationRoot: destinationRoot) {
                skippedAlreadyConsolidatedCount += 1
                alreadyConsolidatedBytes += fileSize
                continue
            }

            let descriptor = sourceDescriptor(for: sourceURL, homeDirectory: homeDirectory)
            let groupDirectory = sourceGroupDirectory(for: sourceURL, baseURL: descriptor.baseURL)
            let groupKey = groupDirectory.path

            var destinationURL = destinationRoot
                .appendingPathComponent(sourceURL.lastPathComponent)

            destinationURL = uniquedDestinationURL(
                destinationURL,
                reservedDestinations: &reservedDestinations,
                fileManager: fileManager
            )

            moves.append(
                .init(
                    id: track.seratoStoredPath,
                    originalStoredPath: track.seratoStoredPath,
                    sourceURL: sourceURL,
                    destinationURL: destinationURL,
                    sourceGroupID: groupKey,
                    sourceGroupTitle: descriptor.title,
                    displayName: track.title.isEmpty ? sourceURL.lastPathComponent : track.title
                )
            )

            groupCounts[groupKey, default: 0] += 1
            groupTitles[groupKey] = groupDirectory.lastPathComponent.isEmpty ? descriptor.title : groupDirectory.lastPathComponent
            groupPaths[groupKey] = groupDirectory.path
            groupBytes[groupKey, default: 0] += fileSize
            queuedTransferBytes += fileSize
        }

        let sourceGroups = groupCounts.keys.sorted().map { key in
            LibraryConsolidationPreview.SourceGroup(
                id: key,
                title: groupTitles[key] ?? "Source",
                trackCount: groupCounts[key] ?? 0,
                examplePath: groupPaths[key] ?? key,
                totalBytes: groupBytes[key] ?? 0
            )
        }

        return LibraryConsolidationPreview(
            destinationFolderURL: destinationRoot,
            moves: moves,
            sourceGroups: sourceGroups,
            skippedMissingCount: skippedMissingCount,
            skippedAlreadyConsolidatedCount: skippedAlreadyConsolidatedCount,
            skippedDuplicatePathCount: skippedDuplicatePathCount,
            totalExistingBytes: totalExistingBytes,
            queuedTransferBytes: queuedTransferBytes,
            alreadyConsolidatedBytes: alreadyConsolidatedBytes
        )
    }

    public static func filteredPreview(
        _ preview: LibraryConsolidationPreview,
        includingSourceGroupIDs selectedSourceGroupIDs: Set<String>
    ) -> LibraryConsolidationPreview {
        guard !selectedSourceGroupIDs.isEmpty else {
            return LibraryConsolidationPreview(
                destinationFolderURL: preview.destinationFolderURL,
                moves: [],
                sourceGroups: [],
                skippedMissingCount: preview.skippedMissingCount,
                skippedAlreadyConsolidatedCount: preview.skippedAlreadyConsolidatedCount,
                skippedDuplicatePathCount: preview.skippedDuplicatePathCount,
                totalExistingBytes: preview.totalExistingBytes,
                queuedTransferBytes: 0,
                alreadyConsolidatedBytes: preview.alreadyConsolidatedBytes
            )
        }

        let filteredMoves = preview.moves.filter { selectedSourceGroupIDs.contains($0.sourceGroupID) }
        let filteredGroups = preview.sourceGroups.filter { selectedSourceGroupIDs.contains($0.id) }
        let filteredQueuedBytes = filteredGroups.reduce(Int64(0)) { partial, group in
            partial + group.totalBytes
        }

        return LibraryConsolidationPreview(
            destinationFolderURL: preview.destinationFolderURL,
            moves: filteredMoves,
            sourceGroups: filteredGroups,
            skippedMissingCount: preview.skippedMissingCount,
            skippedAlreadyConsolidatedCount: preview.skippedAlreadyConsolidatedCount,
            skippedDuplicatePathCount: preview.skippedDuplicatePathCount,
            totalExistingBytes: preview.totalExistingBytes,
            queuedTransferBytes: filteredQueuedBytes,
            alreadyConsolidatedBytes: preview.alreadyConsolidatedBytes
        )
    }

    public static func consolidate(
        preview: LibraryConsolidationPreview,
        mode: FileTransferMode,
        crates: [Crate],
        rootDirectory: URL,
        databaseFileURL: URL,
        fileManager: FileManager = .default
    ) throws -> ConsolidationResult {
        guard !SeratoProcessGuard.isSeratoRunning else {
            throw ConsolidationError.seratoIsRunning
        }
        guard !preview.moves.isEmpty else {
            throw ConsolidationError.noTracksToMove
        }

        let pathMap = Dictionary(
            uniqueKeysWithValues: preview.moves.map { move in
                (move.originalStoredPath, SeratoLibraryLocator.seratoStoredPath(for: move.destinationURL, rootDirectory: rootDirectory))
            }
        )

        let transferredPairs = try transferFiles(preview.moves, mode: mode, fileManager: fileManager)

        do {
            _ = try SeratoPathRewriter.rewritePaths(pathMap, in: databaseFileURL)

            var updatedCrateCount = 0
            for crate in crates {
                let rewrittenPaths = crate.trackPaths.map { pathMap[$0] ?? $0 }
                guard rewrittenPaths != crate.trackPaths else { continue }
                _ = try SeratoCrateEditor.rewriteTrackPaths(in: crate, to: rewrittenPaths)
                updatedCrateCount += 1
            }

            return ConsolidationResult(
                processedTrackCount: transferredPairs.count,
                updatedCrateCount: updatedCrateCount,
                destinationFolderURL: preview.destinationFolderURL,
                mode: mode
            )
        } catch {
            throw error
        }
    }

    private struct SourceDescriptor {
        let title: String
        let destinationPrefix: String
        let baseURL: URL
        let examplePath: String
    }

    private static func transferFiles(
        _ moves: [LibraryConsolidationPreview.Move],
        mode: FileTransferMode,
        fileManager: FileManager
    ) throws -> [(sourceURL: URL, destinationURL: URL)] {
        var transferredPairs: [(sourceURL: URL, destinationURL: URL)] = []

        do {
            for move in moves {
                let destinationDirectory = move.destinationURL.deletingLastPathComponent()
                try fileManager.createDirectory(at: destinationDirectory, withIntermediateDirectories: true)
                do {
                    switch mode {
                    case .move:
                        try fileManager.moveItem(at: move.sourceURL, to: move.destinationURL)
                    case .copy:
                        try fileManager.copyItem(at: move.sourceURL, to: move.destinationURL)
                    }
                } catch {
                    throw ConsolidationError.fileTransferFailed(move.sourceURL, move.destinationURL, mode: mode, underlying: error)
                }
                transferredPairs.append((move.sourceURL, move.destinationURL))
            }
            return transferredPairs
        } catch {
            for pair in transferredPairs.reversed() {
                do {
                    if fileManager.fileExists(atPath: pair.destinationURL.path) {
                        switch mode {
                        case .move:
                            let sourceDirectory = pair.sourceURL.deletingLastPathComponent()
                            try fileManager.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
                            try fileManager.moveItem(at: pair.destinationURL, to: pair.sourceURL)
                        case .copy:
                            try fileManager.removeItem(at: pair.destinationURL)
                        }
                    }
                } catch {
                    throw ConsolidationError.rollbackFailed(pair.sourceURL, pair.destinationURL)
                }
            }
            throw error
        }
    }

    private static func fileSizeOfItem(at url: URL, fileManager: FileManager) -> Int64? {
        guard let attributes = try? fileManager.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? NSNumber else {
            return nil
        }
        return size.int64Value
    }

    private static func sourceDescriptor(for sourceURL: URL, homeDirectory: URL) -> SourceDescriptor {
        let standardizedURL = sourceURL.standardizedFileURL
        let standardizedHome = homeDirectory.standardizedFileURL
        let commonHomeFolders = ["Desktop", "Downloads", "Documents", "Music", "Movies", "Pictures"]

        for folder in commonHomeFolders {
            let folderURL = standardizedHome.appendingPathComponent(folder, isDirectory: true)
            if isDescendant(standardizedURL, of: folderURL) {
                return SourceDescriptor(
                    title: folder,
                    destinationPrefix: folder,
                    baseURL: folderURL,
                    examplePath: folderURL.path
                )
            }
        }

        if isDescendant(standardizedURL, of: standardizedHome) {
            return SourceDescriptor(
                title: "Home Folder",
                destinationPrefix: "Home Folder",
                baseURL: standardizedHome,
                examplePath: standardizedHome.path
            )
        }

        let components = standardizedURL.pathComponents
        if components.count > 2, components[1] == "Volumes" {
            let volumeName = components[2]
            let baseURL = URL(fileURLWithPath: "/Volumes").appendingPathComponent(volumeName, isDirectory: true)
            return SourceDescriptor(
                title: "Drive: \(volumeName)",
                destinationPrefix: "Drives/\(volumeName)",
                baseURL: baseURL,
                examplePath: baseURL.path
            )
        }

        return SourceDescriptor(
            title: "System Folders",
            destinationPrefix: "System Folders",
            baseURL: URL(fileURLWithPath: "/", isDirectory: true),
            examplePath: "/"
        )
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

    private static func isInsideDestination(sourceURL: URL, destinationRoot: URL) -> Bool {
        isDescendant(sourceURL, of: destinationRoot)
    }

    private static func isDescendant(_ child: URL, of parent: URL) -> Bool {
        let childComponents = child.standardizedFileURL.pathComponents
        let parentComponents = parent.standardizedFileURL.pathComponents
        return childComponents.starts(with: parentComponents)
    }

    private static func sourceGroupDirectory(for sourceURL: URL, baseURL: URL) -> URL {
        let sourceDirectory = sourceURL.deletingLastPathComponent().standardizedFileURL
        return sourceDirectory
    }
}