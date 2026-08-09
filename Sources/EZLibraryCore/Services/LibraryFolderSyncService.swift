// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Foundation

public enum LibraryFolderSyncService {
    public struct Rename: Sendable {
        public let from: URL
        public let to: URL

        public init(from: URL, to: URL) {
            self.from = from
            self.to = to
        }
    }

    public struct SyncResult: Sendable {
        public let scannedAudioFiles: Int
        public let insertedTracks: Int
        public let alreadyPresentTracks: Int
        /// The files that were actually added to the database, so a caller can
        /// act on just those rather than on everything it scanned.
        public let insertedFileURLs: [URL]
        /// Files renamed to match the naming template.
        public let renamedFiles: [Rename]
        /// Files that would have been renamed but whose target name was taken.
        public let renameSkippedCount: Int

        public init(
            scannedAudioFiles: Int,
            insertedTracks: Int,
            alreadyPresentTracks: Int,
            insertedFileURLs: [URL] = [],
            renamedFiles: [Rename] = [],
            renameSkippedCount: Int = 0
        ) {
            self.scannedAudioFiles = scannedAudioFiles
            self.insertedTracks = insertedTracks
            self.alreadyPresentTracks = alreadyPresentTracks
            self.insertedFileURLs = insertedFileURLs
            self.renamedFiles = renamedFiles
            self.renameSkippedCount = renameSkippedCount
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
        filenameTemplate: String = TrackFilenameFormatter.defaultTemplate,
        renameFilesFromTags: Bool = false,
        fileManager: FileManager = .default
    ) async throws -> SyncResult {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: folderURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw SyncError.folderNotFound(folderURL)
        }

        guard fileManager.fileExists(atPath: databaseFileURL.path) else {
            throw SyncError.databaseNotFound(databaseFileURL)
        }

        let discovered = AddMusicImportService.discoverAudioFiles(from: [folderURL], fileManager: fileManager)
        guard !discovered.isEmpty else {
            throw SyncError.noSupportedAudioFiles(folderURL)
        }

        return try await syncAudioFiles(
            discovered,
            databaseFileURL: databaseFileURL,
            rootDirectory: rootDirectory,
            filenameTemplate: filenameTemplate,
            renameFilesFromTags: renameFilesFromTags,
            fileManager: fileManager
        )
    }

    public static func syncAudioFiles(
        _ audioFiles: [URL],
        databaseFileURL: URL,
        rootDirectory: URL,
        filenameTemplate: String = TrackFilenameFormatter.defaultTemplate,
        renameFilesFromTags: Bool = false,
        fileManager: FileManager = .default
    ) async throws -> SyncResult {
        guard fileManager.fileExists(atPath: databaseFileURL.path) else {
            throw SyncError.databaseNotFound(databaseFileURL)
        }

        let normalizedAudioFiles = normalizedSupportedExistingFiles(audioFiles, fileManager: fileManager)
        guard !normalizedAudioFiles.isEmpty else {
            throw SyncError.noSupportedAudioFiles(databaseFileURL.deletingLastPathComponent())
        }

        try SeratoBackupBeforeWrite.snapshot(of: databaseFileURL)
        var data = try Data(contentsOf: databaseFileURL)

        var inserted = 0
        var alreadyPresent = 0

        // Match on the file each entry actually points at rather than on the
        // raw stored string. A library holds both path conventions —
        // volume-relative ("Music/x.mp3") and filesystem-root-relative
        // ("Users/me/Music/x.mp3"), which `SeratoLibraryLocator.resolve`
        // documents — and comparing the strings meant a track stored in the
        // other convention was never recognised, so every sync appended a
        // second entry for a file already in the library.
        var presentFiles = Set(
            SeratoDatabaseParser.storedPaths(from: data).map { storedPath in
                SeratoLibraryLocator.resolve(
                    seratoStoredPath: storedPath,
                    rootDirectory: rootDirectory,
                    fileManager: fileManager
                ).standardizedFileURL.path
            }
        )

        var missingFiles: [URL] = []
        for fileURL in normalizedAudioFiles {
            if presentFiles.insert(fileURL.path).inserted {
                missingFiles.append(fileURL)
            } else {
                alreadyPresent += 1
            }
        }

        // Reading tags means opening every file, so the reads run concurrently
        // and the database is appended to afterwards in the original order.
        let metadataByPath = await metadata(for: missingFiles, template: filenameTemplate)

        var renamedFiles: [Rename] = []
        var renameSkipped = 0
        var insertedFiles: [URL] = []
        // Old -> new stored path for every rename, applied to the crates in one
        // pass afterwards.
        var renamedStoredPaths: [String: String] = [:]

        for fileURL in missingFiles {
            let resolved = metadataByPath[fileURL.path]
            var finalURL = fileURL

            // Rename only when the file's own tags produced the name. Renaming
            // from a filename guess would just rewrite a guess as if it were
            // fact, and the guess came from the very name being replaced.
            if renameFilesFromTags, let resolved, resolved.hasUsableTags,
               let proposed = proposedRenameURL(
                   for: fileURL,
                   metadata: resolved.metadata,
                   template: filenameTemplate
               ) {
                if fileManager.fileExists(atPath: proposed.path) {
                    // Something already owns that name; keep ours rather than
                    // inventing a "(2)" variant.
                    renameSkipped += 1
                } else {
                    do {
                        try fileManager.moveItem(at: fileURL, to: proposed)
                        renamedFiles.append(Rename(from: fileURL, to: proposed))
                        renamedStoredPaths[
                            SeratoLibraryLocator.seratoStoredPath(for: fileURL, rootDirectory: rootDirectory)
                        ] = SeratoLibraryLocator.seratoStoredPath(for: proposed, rootDirectory: rootDirectory)
                        finalURL = proposed
                    } catch {
                        renameSkipped += 1
                    }
                }
            }

            let storedPath = SeratoLibraryLocator.seratoStoredPath(for: finalURL, rootDirectory: rootDirectory)
            data = SeratoDatabaseWriter.appendingTrack(
                storedPath: storedPath,
                metadata: resolved?.metadata,
                to: data
            )
            insertedFiles.append(finalURL)
            inserted += 1
        }

        if inserted > 0 {
            try AtomicFileWriter.write(data, to: databaseFileURL)
        }

        // A crate can list a track that `database V2` doesn't have — that is
        // exactly the file this sync treats as new. Renaming it without
        // repointing the crate would drop it out of that crate, so the crates
        // are repointed for every rename.
        try rewriteCratePaths(
            renamedStoredPaths,
            libraryDirectory: databaseFileURL.deletingLastPathComponent()
        )

        return SyncResult(
            scannedAudioFiles: normalizedAudioFiles.count,
            insertedTracks: inserted,
            alreadyPresentTracks: alreadyPresent,
            insertedFileURLs: insertedFiles,
            renamedFiles: renamedFiles,
            renameSkippedCount: renameSkipped
        )
    }

    /// Metadata for one file, and whether the file's own tags supplied the
    /// fields a filename is built from. Renaming is only ever allowed on the
    /// strength of real tags, never on a filename guess.
    struct ResolvedMetadata: Sendable {
        let metadata: SeratoTrackMetadataUpdate
        let hasUsableTags: Bool
    }

    /// Resolves metadata for several files at once, reading their tags
    /// concurrently. Keyed by `URL.path` so the caller can append in order.
    private static func metadata(
        for fileURLs: [URL],
        template: String,
        maxConcurrentReads: Int = 8
    ) async -> [String: ResolvedMetadata] {
        guard !fileURLs.isEmpty else { return [:] }

        var resolved: [String: ResolvedMetadata] = [:]
        var iterator = fileURLs.makeIterator()

        await withTaskGroup(of: (String, ResolvedMetadata).self) { group in
            func addNext() {
                guard let fileURL = iterator.next() else { return }
                group.addTask {
                    (fileURL.path, await metadata(for: fileURL, template: template))
                }
            }

            for _ in 0..<min(maxConcurrentReads, fileURLs.count) { addNext() }

            while let (path, metadata) = await group.next() {
                resolved[path] = metadata
                addNext()
            }
        }

        return resolved
    }

    /// The track's own tags win; the filename is only ever a fallback for the
    /// fields the file doesn't carry.
    ///
    /// Guessing first was the bug users hit: a correctly tagged file whose
    /// name didn't follow the "Artist - Title" shape got a mangled artist and
    /// title written into Serato, and with auto-rename-from-metadata enabled
    /// that guess then renamed the file itself.
    static func metadata(for fileURL: URL, template: String) async -> ResolvedMetadata {
        let tags = await AudioFileTagReader.readTags(from: fileURL)
        let guessed = filenameMetadata(for: fileURL, template: template)

        let metadata = SeratoTrackMetadataUpdate(
            title: nonEmpty(tags.title) ?? guessed.title,
            artist: nonEmpty(tags.artist) ?? guessed.artist,
            album: nonEmpty(tags.album) ?? guessed.album,
            genre: nonEmpty(tags.genre) ?? guessed.genre,
            comment: "",
            key: guessed.key,
            bpm: guessed.bpm,
            year: tags.year ?? guessed.year
        )

        // A name is built from title/artist, so those are the tags that decide
        // whether renaming this file is grounded in the file itself.
        return ResolvedMetadata(
            metadata: metadata,
            hasUsableTags: nonEmpty(tags.title) != nil || nonEmpty(tags.artist) != nil
        )
    }

    private static func nonEmpty(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    /// Everything that can be recovered from the filename alone: the configured
    /// naming template first, then the generic "Artist - Title" heuristic.
    static func filenameMetadata(for fileURL: URL, template: String) -> SeratoTrackMetadataUpdate {
        let rawBaseName = strippingCollisionSuffix(fileURL.deletingPathExtension().lastPathComponent)

        if let fromTemplate = metadataMatchingTemplate(rawBaseName, template: template) {
            return fromTemplate
        }

        let normalized = normalizeFilenameComponent(rawBaseName)
        let (artistGuess, titleGuess) = splitArtistAndTitle(from: normalized)

        return SeratoTrackMetadataUpdate(
            title: titleGuess,
            artist: artistGuess,
            album: "",
            genre: "",
            comment: "",
            key: "",
            bpm: nil,
            year: nil
        )
    }

    /// Repoints every crate that lists a renamed file at its new path.
    ///
    /// Smart crates are included: a `.scrate` keeps a materialized list of
    /// member paths next to its rules, and a stale entry there is what makes
    /// Serato log "Adding track not found in database … but found in crate"
    /// and re-add the file as a second, missing entry.
    private static func rewriteCratePaths(
        _ renamedStoredPaths: [String: String],
        libraryDirectory: URL
    ) throws {
        guard !renamedStoredPaths.isEmpty else { return }

        let entries = SeratoLibraryLocator.subcrateFiles(in: libraryDirectory)
            + SeratoLibraryLocator.smartCrateFiles(in: libraryDirectory)

        for entry in entries {
            let crateData = try Data(contentsOf: entry.url)
            let rewritten = SeratoCrateWriter.rewritingTrackPaths(renamedStoredPaths, in: crateData)
            guard rewritten.rewrittenCount > 0 else { continue }

            try SeratoBackupBeforeWrite.snapshot(of: entry.url)
            try AtomicFileWriter.write(rewritten.data, to: entry.url)
        }
    }

    /// The name `metadata` renders under `template`, or nil when the template
    /// produces nothing or the file already has that name.
    static func proposedRenameURL(
        for fileURL: URL,
        metadata: SeratoTrackMetadataUpdate,
        template: String
    ) -> URL? {
        let stem = TrackFilenameFormatter.renderStem(for: metadata, template: template)
        guard !stem.isEmpty else { return nil }

        let pathExtension = fileURL.pathExtension
        var candidate = fileURL.deletingLastPathComponent().appendingPathComponent(stem)
        if !pathExtension.isEmpty {
            candidate.appendPathExtension(pathExtension)
        }

        guard candidate.lastPathComponent != fileURL.lastPathComponent else { return nil }
        return candidate
    }

    /// Drops the `(2)` that importing adds when a filename is already taken
    /// (see `AddMusicImportService.uniquedDestinationURL`).
    ///
    /// Stripped before any parsing rather than inside the title cleanup: it is
    /// a filesystem artifact, and whichever field the template puts last would
    /// otherwise inherit it — which is how tracks ended up tagged with a
    /// stray "2".
    static func strippingCollisionSuffix(_ baseName: String) -> String {
        var value = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        while let range = value.range(of: #"\s*\(\d{1,3}\)$"#, options: .regularExpression) {
            value.removeSubrange(range)
            value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return value.isEmpty ? baseName : value
    }

    /// Reads a filename back through the naming template the user configured,
    /// so a library named `{artist}-{title}-{album}-{year}` is understood as
    /// those fields instead of being run through the generic heuristic.
    ///
    /// Returns nil whenever the name doesn't confidently fit the template —
    /// a differing separator count, or a `{year}`/`{bpm}` slot holding
    /// something that isn't a number — so the caller falls back rather than
    /// writing a bad split into the database.
    static func metadataMatchingTemplate(_ baseName: String, template: String) -> SeratoTrackMetadataUpdate? {
        let parsed = parseTemplate(template)
        guard parsed.tokens.count >= 2 else { return nil }

        var values: [TrackFilenameFormatter.Token: String] = [:]
        var remainder = baseName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }

        for (index, token) in parsed.tokens.enumerated() {
            let separator = index < parsed.separators.count ? parsed.separators[index] : nil

            guard let separator, !separator.isEmpty else {
                // Last token (or an empty separator): it takes what is left.
                values[token] = remainder.trimmingCharacters(in: .whitespacesAndNewlines)
                remainder = ""
                continue
            }

            guard let range = remainder.range(of: separator) else { return nil }
            values[token] = String(remainder[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
            remainder = String(remainder[range.upperBound...])
        }

        // Leftover text means the name has more segments than the template.
        guard remainder.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }

        // A numeric slot holding something non-numeric means the split landed
        // in the wrong place, so the whole parse is abandoned rather than
        // silently treated as "no value".
        var resolvedYear: Int?
        if let raw = values[.year], !raw.isEmpty {
            guard let parsed = Int(raw), (1000...9999).contains(parsed) else { return nil }
            resolvedYear = parsed
        }

        var resolvedBPM: Double?
        if let raw = values[.bpm], !raw.isEmpty {
            guard let parsed = Double(raw) else { return nil }
            resolvedBPM = parsed
        }

        let title = values[.title] ?? ""
        let artist = values[.artist] ?? ""
        guard !title.isEmpty || !artist.isEmpty else { return nil }

        return SeratoTrackMetadataUpdate(
            title: title,
            artist: artist,
            album: values[.album] ?? "",
            genre: values[.genre] ?? "",
            comment: "",
            key: values[.key] ?? "",
            bpm: resolvedBPM,
            year: resolvedYear
        )
    }

    /// Splits a template into its tokens and the literal text between them.
    /// `separators[i]` is the literal that follows `tokens[i]`, or nil for the
    /// final token.
    private static func parseTemplate(
        _ template: String
    ) -> (tokens: [TrackFilenameFormatter.Token], separators: [String?]) {
        var tokens: [TrackFilenameFormatter.Token] = []
        var separators: [String?] = []
        var literal = ""
        var index = template.startIndex

        outer: while index < template.endIndex {
            for token in TrackFilenameFormatter.Token.allCases
            where template[index...].hasPrefix(token.rawValue) {
                if !tokens.isEmpty {
                    separators.append(literal.isEmpty ? nil : literal)
                }
                literal = ""
                tokens.append(token)
                index = template.index(index, offsetBy: token.rawValue.count)
                continue outer
            }
            literal.append(template[index])
            index = template.index(after: index)
        }

        if !tokens.isEmpty {
            separators.append(literal.isEmpty ? nil : literal)
        }

        return (tokens, separators)
    }

    private static func splitArtistAndTitle(from baseName: String) -> (artist: String, title: String) {
        let separators = [" - ", " – ", " — ", " | ", " : "]
        for separator in separators {
            let parts = baseName.components(separatedBy: separator)
            guard parts.count >= 2 else { continue }

            let artist = normalizeArtistGuess(normalizeFilenameComponent(parts[0]))
            let title = normalizeTitleGuess(normalizeFilenameComponent(parts.dropFirst().joined(separator: separator)))
            if !title.isEmpty {
                return (artist: artist, title: title)
            }
        }

        // Support compact patterns like "Artist-Title" when spaced separators aren't present.
        if !baseName.contains(" - "), let compactRange = baseName.range(of: "-") {
            let left = normalizeArtistGuess(normalizeFilenameComponent(String(baseName[..<compactRange.lowerBound])))
            let right = normalizeTitleGuess(normalizeFilenameComponent(String(baseName[compactRange.upperBound...])))
            if !left.isEmpty, !right.isEmpty,
               left.rangeOfCharacter(from: .letters) != nil,
               right.rangeOfCharacter(from: .letters) != nil {
                return (artist: left, title: right)
            }
        }

        return (artist: "", title: normalizeTitleGuess(baseName))
    }

    static func normalizeFilenameComponent(_ raw: String) -> String {
        var value = raw.replacingOccurrences(of: "_", with: " ")

        // Strip a leading track-index prefix, but only in the forms an index
        // actually takes — a zero-padded number ("01 - ", "007 ") or a number
        // followed by "." / ")" ("1. ", "3) ").
        //
        // Matching any leading number ate artists whose names start with
        // digits: "50 Cent" became "Cent", "2 Pac" became "Pac", and "112 -
        // Its Over Now" lost its artist entirely. Those are far more common in
        // a DJ library than a bare "3 - " index, so an unpadded number with
        // only a space or dash after it is now left alone.
        let indexPatterns = [
            #"^\s*0\d{1,2}(?:\s*[-._)]\s*|\s+)"#,
            #"^\s*\d{1,3}\s*[.)]\s*"#
        ]
        for pattern in indexPatterns {
            if let range = value.range(of: pattern, options: .regularExpression) {
                value.removeSubrange(range)
                break
            }
        }

        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeArtistGuess(_ raw: String) -> String {
        var value = raw
        value = value.replacingOccurrences(of: #"\s+feat\.?\s+"#, with: " feat. ", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"\s+ft\.?\s+"#, with: " feat. ", options: [.regularExpression, .caseInsensitive])
        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizeTitleGuess(_ raw: String) -> String {
        var value = raw

        value = removeInlineNoisyBracketDescriptors(from: value)

        // Strip common non-title download noise while keeping meaningful mix/remix info.
        while true {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
            if removeTrailingBracketDescriptorIfNoisy(from: &value) {
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if removeTrailingInlineNoiseIfPresent(from: &value) {
                value = value.trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            if value.trimmingCharacters(in: .whitespacesAndNewlines) == trimmed {
                break
            }
        }

        value = value.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func removeInlineNoisyBracketDescriptors(from value: String) -> String {
        let pattern = #"\s*[\(\[\{]([^\)\]\}]*)[\)\]\}]"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }

        var output = value
        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        let matches = regex.matches(in: output, range: fullRange)

        for match in matches.reversed() {
            guard let descriptorRange = Range(match.range(at: 1), in: output),
                  let segmentRange = Range(match.range(at: 0), in: output) else {
                continue
            }

            let descriptor = output[descriptorRange].trimmingCharacters(in: .whitespacesAndNewlines)
            guard shouldStripTrailingNoiseDescriptor(descriptor), !shouldPreserveDJDescriptor(descriptor) else {
                continue
            }

            output.removeSubrange(segmentRange)
        }

        return output
    }

    private static func removeTrailingBracketDescriptorIfNoisy(from value: inout String) -> Bool {
        guard let range = value.range(of: #"\s*[\(\[\{]([^\)\]\}]*)[\)\]\}]\s*$"#, options: .regularExpression) else {
            return false
        }

        let segment = String(value[range])
        let descriptor = segment
            .replacingOccurrences(of: #"^[\s\(\[\{]+"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[\s\)\]\}]+$"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard shouldStripTrailingNoiseDescriptor(descriptor), !shouldPreserveDJDescriptor(descriptor) else {
            return false
        }

        value.removeSubrange(range)
        return true
    }

    private static func removeTrailingInlineNoiseIfPresent(from value: inout String) -> Bool {
        let pattern = #"\s*[-–—|:]\s*(official\s+(video|audio)|music\s+video|lyric(s)?\s*(video)?|visualizer|audio|video|hq|hd|4k|free\s+download|out\s+now)\s*$"#
        guard let range = value.range(of: pattern, options: [.regularExpression, .caseInsensitive]) else {
            return false
        }
        value.removeSubrange(range)
        return true
    }

    private static func shouldStripTrailingNoiseDescriptor(_ descriptor: String) -> Bool {
        let normalized = descriptor
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        if normalized.isEmpty {
            return true
        }

        // A bare number is the collision suffix `uniquedDestinationURL` adds
        // when importing a file whose name is already taken ("Song (2).mp3").
        // It is never part of a title, and leaving it in tagged tracks with a
        // stray "2".
        if normalized.range(of: #"^\d{1,3}$"#, options: .regularExpression) != nil {
            return true
        }

        let noisyPatterns = [
            #"^official(\s+(video|audio))?$"#,
            #"^music\s+video$"#,
            #"^lyric(s)?(\s+video)?$"#,
            #"^visualizer$"#,
            #"^audio$"#,
            #"^video$"#,
            #"^hq$"#,
            #"^hd$"#,
            #"^4k$"#,
            #"^free\s+download$"#,
            #"^out\s+now$"#
        ]

        return noisyPatterns.contains { pattern in
            normalized.range(of: pattern, options: .regularExpression) != nil
        }
    }

    private static func shouldPreserveDJDescriptor(_ descriptor: String) -> Bool {
        let normalized = descriptor
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()

        let preserveTokens = [
            "quick hit",
            "intro",
            "extended",
            "remix",
            "edit",
            "radio edit",
            "club edit",
            "acapella",
            "instrumental",
            "transition",
            "bootleg",
            "mashup",
            "flip",
            "clean",
            "dirty",
            "explicit"
        ]

        return preserveTokens.contains { normalized.contains($0) }
    }

    private static func normalizedSupportedExistingFiles(_ files: [URL], fileManager: FileManager) -> [URL] {
        var seen = Set<String>()
        var output: [URL] = []

        for file in files {
            let normalized = file.standardizedFileURL
            guard AddMusicImportService.supportedAudioExtensions.contains(normalized.pathExtension.lowercased()) else {
                continue
            }
            guard fileManager.fileExists(atPath: normalized.path) else { continue }

            if seen.insert(normalized.path).inserted {
                output.append(normalized)
            }
        }

        return output.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
    }
}