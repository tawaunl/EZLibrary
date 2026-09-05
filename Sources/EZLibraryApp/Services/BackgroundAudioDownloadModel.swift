// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import SwiftUI
import EZLibraryCore

/// Owns an in-flight audio download batch at a level above the Download Audio
/// view.
///
/// The batch loop used to be a `Task` inside `YouTubeRipView`, writing straight
/// to that view's `@State`. Switching sections tears the view down, so its
/// progress and results were lost the moment the user navigated away. Holding
/// the task and its published state here lets a download keep running — with a
/// visible banner — while the user browses crates, edits tags, or matches a
/// playlist.
@MainActor
final class BackgroundAudioDownloadModel: ObservableObject {
    struct RecentDownload: Identifiable {
        let id = UUID()
        let title: String
        let fileName: String
        let crateLabel: String
        let downloadedAt: Date
    }

    /// Where finished files should land: a fresh dated crate, an existing
    /// crate, or nowhere.
    enum CrateAssignment: Sendable {
        case dated(prefix: String)
        case existing(Crate)
        case none
    }

    /// Everything the batch needs, snapshotted from the view at start time so
    /// the job doesn't depend on any view state that may be gone by the time it
    /// finishes.
    struct Request: Sendable {
        var videoURLs: [URL]
        var destinationFolderURL: URL
        var audioFormat: YouTubeAudioImportService.AudioFormat
        var audioQuality: YouTubeAudioImportService.AudioQuality
        var audioBitrateKbps: Int?
        var baseMetadata: SeratoTrackMetadataUpdate
        var writeID3Tags: Bool
        var crateAssignment: CrateAssignment
        var subcratesDirectory: URL
        var rootDirectory: URL
        var databaseFileURL: URL
        var firstParsedURL: URL?
        var loadedInfoSnapshot: YouTubeAudioImportService.VideoInfo?
    }

    private enum SeratoWriteOutcome {
        case inserted
        case updated
        case unchanged
    }

    @Published private(set) var isDownloading = false
    @Published private(set) var progressMessage: String?
    @Published private(set) var completed = 0
    @Published private(set) var total = 0
    @Published var resultMessage: String?
    @Published var errorMessage: String?
    @Published private(set) var seratoStatusMessage: String?
    @Published private(set) var recentDownloads: [RecentDownload] = []
    /// Bumped once per batch that finished at least one file, so the view can
    /// clear its inputs only when it's on screen to see it.
    @Published private(set) var successGeneration = 0

    private var task: Task<Void, Never>?
    /// The app-level reload, held while a batch runs so the completion handler
    /// isn't captured into the (Sendable) task closure.
    private var onLibraryChanged: (() -> Void)?

    var canStart: Bool { !isDownloading }

    /// Starts a batch. `onLibraryChanged` is the app-level reload, invoked once
    /// on completion so a fresh library reflects the new tracks.
    func start(_ request: Request, onLibraryChanged: @escaping () -> Void) {
        guard canStart, !request.videoURLs.isEmpty else { return }

        self.onLibraryChanged = onLibraryChanged
        isDownloading = true
        errorMessage = nil
        resultMessage = nil
        completed = 0
        total = request.videoURLs.count
        progressMessage = "Preparing batch…"

        task = Task { [weak self] in
            await self?.run(request)
        }
    }

    func cancel() {
        task?.cancel()
    }

    func dismissResult() {
        resultMessage = nil
        errorMessage = nil
    }

    // MARK: - Batch

    private func run(_ request: Request) async {
        let videoURLs = request.videoURLs
        var downloadedFileURLs: [URL] = []
        var failures: [String] = []
        var id3Warnings: [String] = []
        var seratoWarnings: [String] = []
        var lastOutcome: SeratoWriteOutcome = .unchanged

        for (index, videoURL) in videoURLs.enumerated() {
            if Task.isCancelled { break }
            completed = index
            progressMessage = "Processing \(index + 1) of \(videoURLs.count)…"

            do {
                let format = request.audioFormat
                let quality = request.audioQuality
                let bitrate = request.audioBitrateKbps
                let metadataForDownload = request.baseMetadata
                let destination = request.destinationFolderURL
                let result = try await Task.detached(priority: .userInitiated) {
                    try YouTubeAudioImportService.downloadAudio(
                        .init(
                            videoURL: videoURL,
                            destinationFolderURL: destination,
                            audioFormat: format,
                            audioQuality: quality,
                            audioBitrateKbps: bitrate,
                            metadata: metadataForDownload
                        )
                    )
                }.value

                let fallbackInfo: YouTubeAudioImportService.VideoInfo?
                if let loadedInfoSnapshot = request.loadedInfoSnapshot, request.firstParsedURL == videoURL {
                    fallbackInfo = loadedInfoSnapshot
                } else {
                    fallbackInfo = try? await Task.detached(priority: .utility) {
                        try YouTubeAudioImportService.fetchVideoInfo(videoURL: videoURL)
                    }.value
                }

                let metadataForDatabaseWrite = enrichMetadata(
                    request.baseMetadata,
                    fallbackInfo: fallbackInfo,
                    downloadedTitle: result.title
                )

                if request.writeID3Tags {
                    do {
                        try SeratoTrackMetadataEditor.writeID3Tags(
                            fileURL: result.outputFileURL,
                            metadata: metadataForDatabaseWrite
                        )
                    } catch {
                        id3Warnings.append("\(result.outputFileURL.lastPathComponent): \(error.localizedDescription)")
                    }
                }

                do {
                    lastOutcome = try writeSeratoMetadataForDownloadedFile(
                        fileURL: result.outputFileURL,
                        rootDirectory: request.rootDirectory,
                        databaseFileURL: request.databaseFileURL,
                        metadata: metadataForDatabaseWrite
                    )
                } catch {
                    seratoWarnings.append("\(result.outputFileURL.lastPathComponent): \(error.localizedDescription)")
                }

                downloadedFileURLs.append(result.outputFileURL)
                completed = index + 1

                appendRecentDownload(
                    title: fallbackInfo?.title ?? result.title,
                    fileName: result.outputFileURL.lastPathComponent,
                    crateLabel: request.crateAssignment.isNone ? "No Crate" : "Queued for crate"
                )
            } catch {
                failures.append("\(videoURL.absoluteString): \(error.localizedDescription)")
            }
        }

        guard !downloadedFileURLs.isEmpty else {
            if Task.isCancelled {
                resultMessage = "Download stopped before any file finished."
            } else {
                var message = "All downloads failed."
                if !failures.isEmpty {
                    message = "All downloads failed. " + failures.prefix(2).joined(separator: " | ")
                }
                errorMessage = message
            }
            progressMessage = nil
            isDownloading = false
            onLibraryChanged = nil
            task = nil
            return
        }

        do {
            let crateResult = try assignCrate(
                request.crateAssignment,
                files: downloadedFileURLs,
                subcratesDirectory: request.subcratesDirectory,
                rootDirectory: request.rootDirectory
            )

            var summary = "Downloaded \(downloadedFileURLs.count) of \(videoURLs.count) link\(videoURLs.count == 1 ? "" : "s")."
            if let crateResult {
                summary += " Saved to crate \(crateResult.crateName)."
            } else {
                summary += " No crate assignment."
            }
            if !id3Warnings.isEmpty {
                summary += " ID3 warnings: \(id3Warnings.count)."
            }
            if !seratoWarnings.isEmpty {
                summary += " Serato warnings: \(seratoWarnings.count)."
            }
            if !failures.isEmpty {
                summary += " Failed: \(failures.count)."
            }

            resultMessage = summary
            errorMessage = nil

            switch lastOutcome {
            case .inserted:
                seratoStatusMessage = "Serato DB: inserted new track row and wrote metadata"
            case .updated:
                seratoStatusMessage = "Serato DB: updated existing track metadata"
            case .unchanged:
                seratoStatusMessage = seratoWarnings.isEmpty ? "Serato DB: track row already up to date" : "Serato DB: some writes failed"
            }

            successGeneration += 1
            onLibraryChanged?()
        } catch {
            var message = error.localizedDescription
            if !failures.isEmpty {
                message += " Failed links: " + failures.prefix(2).joined(separator: " | ")
            }
            errorMessage = message
        }

        progressMessage = nil
        isDownloading = false
        onLibraryChanged = nil
        task = nil
    }

    private func assignCrate(
        _ assignment: CrateAssignment,
        files: [URL],
        subcratesDirectory: URL,
        rootDirectory: URL
    ) throws -> AddMusicImportService.CrateCreationResult? {
        switch assignment {
        case let .dated(prefix):
            return try AddMusicImportService.createDatedCrate(
                forAudioFiles: files,
                crateNamePrefix: prefix,
                subcratesDirectory: subcratesDirectory,
                rootDirectory: rootDirectory
            )
        case let .existing(crate):
            return try AddMusicImportService.appendAudioFiles(
                files,
                toExistingCrate: crate,
                rootDirectory: rootDirectory
            )
        case .none:
            return nil
        }
    }

    private func appendRecentDownload(title: String, fileName: String, crateLabel: String) {
        let resolvedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? fileName : title
        recentDownloads.insert(
            RecentDownload(
                title: resolvedTitle,
                fileName: fileName,
                crateLabel: crateLabel,
                downloadedAt: Date()
            ),
            at: 0
        )
        if recentDownloads.count > 5 {
            recentDownloads = Array(recentDownloads.prefix(5))
        }
    }

    private func enrichMetadata(
        _ metadata: SeratoTrackMetadataUpdate,
        fallbackInfo: YouTubeAudioImportService.VideoInfo?,
        downloadedTitle: String
    ) -> SeratoTrackMetadataUpdate {
        var out = metadata

        if out.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let rawTitle = fallbackInfo?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let parsed = YouTubeTitleParser.parse(
                videoTitle: rawTitle.isEmpty ? downloadedTitle : rawTitle,
                uploader: fallbackInfo?.uploader)
            out.title = parsed.title.isEmpty ? downloadedTitle : parsed.title
        }

        if out.artist.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            out.artist = YouTubeTitleParser.parse(
                videoTitle: fallbackInfo?.title ?? downloadedTitle,
                uploader: fallbackInfo?.uploader
            ).artist
        }

        if out.year == nil,
           let uploadDate = fallbackInfo?.uploadDate,
           uploadDate.count >= 4,
           let parsedYear = Int(uploadDate.prefix(4)) {
            out.year = parsedYear
        }

        return out
    }

    private func writeSeratoMetadataForDownloadedFile(
        fileURL: URL,
        rootDirectory: URL,
        databaseFileURL: URL,
        metadata: SeratoTrackMetadataUpdate
    ) throws -> SeratoWriteOutcome {
        if FileManager.default.fileExists(atPath: databaseFileURL.path) {
            try SeratoBackupBeforeWrite.snapshot(of: databaseFileURL)
        }

        let original = try Data(contentsOf: databaseFileURL)
        let defaultStoredPath = SeratoLibraryLocator.seratoStoredPath(for: fileURL, rootDirectory: rootDirectory)
        let storedPath = findExistingStoredPath(
            for: fileURL,
            rootDirectory: rootDirectory,
            in: original
        ) ?? defaultStoredPath

        let ensured = SeratoDatabaseWriter.ensuringTrackExists(
            forStoredPath: storedPath,
            metadata: metadata,
            in: original
        )

        let rewritten = SeratoDatabaseWriter.rewritingMetadata(
            forStoredPath: storedPath,
            metadata: metadata,
            in: ensured.data
        )

        if ensured.didInsert || rewritten.didRewrite {
            try AtomicFileWriter.write(rewritten.data, to: databaseFileURL)
        }

        if ensured.didInsert {
            return .inserted
        }
        if rewritten.didRewrite {
            return .updated
        }
        return .unchanged
    }

    private func findExistingStoredPath(
        for fileURL: URL,
        rootDirectory: URL,
        in databaseData: Data
    ) -> String? {
        let targetPaths = canonicalFilePaths(for: fileURL)

        for chunk in SeratoChunkCodec.readChunks(from: databaseData) where chunk.tag == "otrk" {
            let fields = SeratoChunkCodec.readChunks(from: chunk.payload)
            guard let pfil = fields.first(where: { $0.tag == "pfil" }) else { continue }

            let storedPath = SeratoChunkCodec.decodeUTF16BEString(pfil.payload)
            let resolvedURL = SeratoLibraryLocator.resolve(seratoStoredPath: storedPath, rootDirectory: rootDirectory)
            if targetPaths.contains(canonicalPathString(for: resolvedURL)) {
                return storedPath
            }
        }

        return nil
    }

    private func canonicalFilePaths(for fileURL: URL) -> Set<String> {
        var paths: Set<String> = []
        paths.insert(canonicalPathString(for: fileURL))
        paths.insert(canonicalPathString(for: fileURL.standardizedFileURL))
        paths.insert(canonicalPathString(for: fileURL.resolvingSymlinksInPath().standardizedFileURL))
        return paths
    }

    private func canonicalPathString(for fileURL: URL) -> String {
        var path = fileURL.resolvingSymlinksInPath().standardizedFileURL.path
        if path.hasPrefix("/private/") {
            path.removeFirst("/private".count)
        }
        return path
    }
}

private extension BackgroundAudioDownloadModel.CrateAssignment {
    var isNone: Bool {
        if case .none = self { return true }
        return false
    }
}
