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

/// The filesystem a USB stick is formatted with, as far as CDJs care.
public enum CDJStickFormat: String, Sendable {
    case fat32, exfat, hfsPlus, apfs, ntfs, unknown

    /// Reads the filesystem type of the volume holding `url`.
    public static func detect(at url: URL) -> CDJStickFormat {
        var stats = statfs()
        guard statfs(url.path, &stats) == 0 else { return .unknown }
        let name = withUnsafePointer(to: &stats.f_fstypename) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MFSNAMELEN)) { String(cString: $0) }
        }
        switch name {
        case "msdos": return .fat32
        case "exfat": return .exfat
        case "hfs": return .hfsPlus
        case "apfs": return .apfs
        case "ntfs": return .ntfs
        default: return .unknown
        }
    }

    /// Why the stick can't be used, or nil when it can.
    public var blockingProblem: String? {
        switch self {
        case .apfs: return "APFS isn't readable by CDJs. Reformat the stick as FAT32 (MBR)."
        case .ntfs: return "NTFS isn't readable by CDJs. Reformat the stick as FAT32 (MBR)."
        case .unknown: return "Couldn't tell how this drive is formatted. CDJs need FAT32 (MBR)."
        default: return nil
        }
    }

    /// Something to tell the user that doesn't stop the export.
    public var caution: String? {
        switch self {
        case .exfat:
            return "exFAT only works on newer players (CDJ-3000, XDJ-XZ, XDJ-RX3 and later). "
                + "FAT32 (MBR) works on every player."
        case .hfsPlus:
            return "HFS+ only works on players from 2009 on, and must not be journaled."
        default: return nil
        }
    }
}

public struct CDJExportPlan: Sendable {
    public struct Item: Sendable {
        /// The Serato library path the track is identified by.
        public let key: String
        public let source: URL
        public let sourceModified: Double
        public let export: CDJExportTrack
    }

    /// A file from an earlier export that this one no longer wants.
    public struct Removal: Sendable, Equatable {
        public let stickPath: String
        public let analyzePath: String
    }

    public var items: [Item]
    public var playlists: [CDJExportPlaylist]
    /// Tracks in the chosen crates whose audio file isn't on disk.
    public var missing: [Track]
    /// Tracks in a file type CDJs can't play.
    public var unsupported: [Track]
    /// `PIONEER` or `.PIONEER`: the folder the stick keeps its library in.
    public var root: String = "PIONEER"
    /// The manifest this plan was made against, to notice the stick changing under it.
    public var previous: CDJExportManifest?
    /// The manifest to write if the export succeeds.
    public var manifest: CDJExportManifest
    /// Tracks from an earlier export that are no longer selected, and will be removed.
    public var removals: [Removal] = []

    public var totalBytes: Int { items.reduce(0) { $0 + $1.export.fileSize } }
}

public struct CDJExportResult: Sendable, Equatable {
    public var tracksWritten: Int
    public var filesCopied: Int
    public var filesAlreadyOnStick: Int
    public var playlistCount: Int
    /// Tracks that got beat grid, cue and waveform files.
    public var analysisFilesWritten: Int = 0
    /// Tracks with no Serato cues, loops or beatgrid to carry over (never
    /// analysed in Serato), so they got a waveform only.
    public var tracksWithoutSeratoAnalysis: Int = 0
    /// Tracks from an earlier export taken off the stick because they were unticked.
    public var tracksRemoved: Int = 0
    /// An earlier export was interrupted; the stick was put back before this one started.
    public var recoveredInterruptedExport: Bool = false
}

public enum CDJExportError: LocalizedError {
    case notAVolume(URL)
    case unusableFormat(String)
    case notEnoughSpace(needed: Int, available: Int)
    case nothingToExport
    case conflictingRoots
    case stickChanged
    case verificationFailed(String)

    public var errorDescription: String? {
        switch self {
        case .notAVolume(let url):
            return "\(url.path) isn't a USB drive."
        case .unusableFormat(let reason):
            return reason
        case .notEnoughSpace(let needed, let available):
            let format = ByteCountFormatter()
            return "The selected crates need \(format.string(fromByteCount: Int64(needed))) "
                + "but the stick has \(format.string(fromByteCount: Int64(available))) free."
        case .nothingToExport:
            return "None of the selected crates contain playable tracks."
        case .conflictingRoots:
            return "This stick has a library under both PIONEER and .PIONEER, so it isn't clear which to update."
        case .stickChanged:
            return "The stick changed while the export was being prepared."
        case .verificationFailed(let detail):
            return "The export didn't verify, so the stick was left as it was. \(detail)"
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notAVolume: return "Choose a drive under /Volumes."
        case .unusableFormat: return "Reformat the stick in Disk Utility, then try again."
        case .notEnoughSpace: return "Pick fewer crates or use a larger stick."
        case .nothingToExport: return "Pick crates that contain tracks."
        case .conflictingRoots: return "Remove one of the two folders, then try again."
        case .stickChanged: return "Close anything else using the stick and export again."
        case .verificationFailed: return "Try again. If it keeps failing, report the message above."
        }
    }
}

/// The parts of the outside world an export touches, so tests can stand in for a stick.
struct CDJExportEnvironment: Sendable {
    var requireVolumePath = true
    var detectFormat: @Sendable (URL) -> CDJStickFormat = { CDJStickFormat.detect(at: $0) }
    var freeBytes: @Sendable (URL) -> Int = {
        (try? $0.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? Int.max
    }

    static let live = CDJExportEnvironment()
}

/// Copies Serato crates onto a USB stick in the layout Pioneer CDJs and XDJs
/// browse: audio under `Contents/`, analysis files (beat grid, cues, waveforms)
/// under `PIONEER/USBANLZ/`, and a database at `PIONEER/rekordbox/export.pdb`
/// so each crate shows up as a playlist.
///
/// Read-only with respect to Serato: nothing in the library is modified. Each
/// run is staged on the stick, verified, then published with a journal so an
/// interruption can be undone; track ids stay the same from one run to the next.
public enum CDJSeratoExport {
    static func databasePath(root: String) -> String { "\(root)/rekordbox/export.pdb" }

    /// Reads what a previous export left on `volume`, and which root it uses.
    public static func stickState(at volume: URL) throws -> (root: String, manifest: CDJExportManifest?) {
        let format = CDJStickFormat.detect(at: volume)
        let root = try CDJExportRoot.select(on: volume, format: format)
        return (root, CDJExportManifest.load(from: volume, root: root))
    }

    /// Works out what an export would do, without touching the stick.
    public static func plan(
        crates: [Crate], library tracks: [Track],
        previous: CDJExportManifest? = nil, root: String = "PIONEER"
    ) -> CDJExportPlan {
        let byPath = Dictionary(tracks.map { ($0.seratoStoredPath, $0) }, uniquingKeysWith: { first, _ in first })
        let fileManager = FileManager.default
        let previousTracks = Dictionary(
            (previous?.tracks ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        let previousPlaylists = Dictionary(
            (previous?.playlists ?? []).map { ($0.key, $0.id) }, uniquingKeysWith: { first, _ in first })
        let sortedCrates = crates.sorted { $0.pathComponents.lexicographicallyPrecedes($1.pathComponents) }

        // 1. The distinct playable tracks, in the order the crates first use them.
        var ordered: [(track: Track, type: CDJFileType)] = []
        var seen = Set<String>()
        var missing: [Track] = []
        var unsupported: [Track] = []
        for crate in sortedCrates {
            for path in crate.trackPaths {
                guard let track = byPath[path], seen.insert(path).inserted else { continue }
                guard let type = CDJFileType(pathExtension: track.fileURL.pathExtension) else {
                    unsupported.append(track)
                    continue
                }
                guard fileManager.fileExists(atPath: track.fileURL.path) else {
                    missing.append(track)
                    continue
                }
                ordered.append((track, type))
            }
        }

        // 2. Ids and paths. Tracks already on the stick keep both, so decks keep their caches.
        var nextTrackID = previous?.nextTrackID ?? 1
        var usedStickPaths = Set<String>()
        var usedAnalyzePaths = Set<String>()
        var stickPaths: [String: String] = [:]
        var analyzePaths: [String: String] = [:]
        var ids: [String: UInt32] = [:]

        func claim(_ track: Track, preferred: CDJExportManifest.TrackRecord?) {
            let key = track.seratoStoredPath
            let id: UInt32
            if let preferred { id = preferred.id } else { id = nextTrackID; nextTrackID += 1 }
            ids[key] = id
            var stickPath: String
            if let preferred, sameExtension(preferred.stickPath, track),
               !usedStickPaths.contains(preferred.stickPath.lowercased()) {
                stickPath = preferred.stickPath
                usedStickPaths.insert(stickPath.lowercased())
            } else {
                stickPath = uniqueStickPath(for: track, used: &usedStickPaths)
            }
            var analyzePath = RekordboxAnalysisPath.datPath(forAudioPath: stickPath, root: root)
            // Two audio paths that hash to the same folder would share analysis files.
            var attempt = 0
            while !usedAnalyzePaths.insert(analyzePath).inserted {
                attempt += 1
                stickPath = withSuffix("-\(id)" + (attempt > 1 ? "-\(attempt)" : ""), to: stickPath)
                usedStickPaths.insert(stickPath.lowercased())
                analyzePath = RekordboxAnalysisPath.datPath(forAudioPath: stickPath, root: root)
            }
            stickPaths[key] = stickPath
            analyzePaths[key] = analyzePath
        }
        // Existing tracks first, so a new track can't take a path an old one is keeping.
        for entry in ordered where previousTracks[entry.track.seratoStoredPath] != nil {
            claim(entry.track, preferred: previousTracks[entry.track.seratoStoredPath])
        }
        for entry in ordered where previousTracks[entry.track.seratoStoredPath] == nil {
            claim(entry.track, preferred: nil)
        }

        var items: [CDJExportPlan.Item] = []
        var records: [CDJExportManifest.TrackRecord] = []
        let libraryID = previous?.libraryID ?? UInt32.random(in: 1...UInt32.max)
        for (track, type) in ordered {
            let key = track.seratoStoredPath
            guard let id = ids[key], let stickPath = stickPaths[key], let analyzePath = analyzePaths[key] else { continue }
            // A URL caches file attributes, and library URLs live a long time: read through a fresh one.
            let values = try? URL(fileURLWithPath: track.fileURL.path)
                .resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
            let size = values?.fileSize ?? 0
            let modified = values?.contentModificationDate?.timeIntervalSince1970 ?? 0
            let title = track.title.isEmpty ? track.fileURL.deletingPathExtension().lastPathComponent : track.title
            items.append(CDJExportPlan.Item(
                key: key, source: track.fileURL, sourceModified: modified,
                export: CDJExportTrack(
                    id: id, title: title,
                    artist: track.artist, album: track.album, genre: track.genre,
                    label: track.label, comment: track.comment, year: track.year ?? 0,
                    durationSeconds: Int(track.duration ?? 0), bpm: track.bpm ?? 0,
                    bitrate: Int(track.bitrate?.filter(\.isNumber) ?? "") ?? 0,
                    sampleRate: Int(track.sampleRate?.filter(\.isNumber) ?? "") ?? 44_100,
                    fileSize: size, trackNumber: track.trackNumber ?? 0, fileType: type,
                    stickPath: stickPath, dateAdded: dateString(track.dateAdded),
                    analyzePath: analyzePath)))
            records.append(CDJExportManifest.TrackRecord(
                key: key, id: id, stickPath: stickPath, analyzePath: analyzePath,
                sourceSize: size, sourceModified: modified, copySize: size))
        }

        // 3. Playlists, numbered from 0 among their siblings and keeping their ids.
        var nextPlaylistID = previous?.nextPlaylistID ?? 1
        var playlists: [CDJExportPlaylist] = []
        var playlistRecords: [CDJExportManifest.PlaylistRecord] = []
        var folderIDs: [[String]: UInt32] = [:]
        var usedPlaylistIDs = Set<UInt32>()
        var siblingCounts: [UInt32: UInt32] = [:]

        func playlistID(kind: String, path: [String]) -> UInt32 {
            let key = kind + path.joined(separator: Crate.nestingDelimiter)
            var id = previousPlaylists[key] ?? 0
            if id == 0 || !usedPlaylistIDs.insert(id).inserted {
                repeat { id = nextPlaylistID; nextPlaylistID += 1 } while !usedPlaylistIDs.insert(id).inserted
            }
            playlistRecords.append(.init(key: key, id: id))
            return id
        }
        func nextSortOrder(parent: UInt32) -> UInt32 {
            defer { siblingCounts[parent, default: 0] += 1 }
            return siblingCounts[parent, default: 0]
        }

        for crate in sortedCrates {
            var parentID: UInt32 = 0
            for depth in 1..<max(crate.pathComponents.count, 1) {
                let path = Array(crate.pathComponents.prefix(depth))
                if let existing = folderIDs[path] {
                    parentID = existing
                } else {
                    let id = playlistID(kind: "f:", path: path)
                    playlists.append(CDJExportPlaylist(
                        id: id, parentID: parentID, name: path[depth - 1], isFolder: true,
                        sortOrder: nextSortOrder(parent: parentID)))
                    folderIDs[path] = id
                    parentID = id
                }
            }
            let trackIDs = crate.trackPaths.compactMap { byPath[$0] }.compactMap { ids[$0.seratoStoredPath] }
            playlists.append(CDJExportPlaylist(
                id: playlistID(kind: "p:", path: crate.pathComponents), parentID: parentID, name: crate.name,
                sortOrder: nextSortOrder(parent: parentID), trackIDs: trackIDs))
        }

        // 4. Whatever the last export put on the stick that this one drops or moves.
        let keptPaths = Set(items.flatMap { [$0.export.stickPath.lowercased(), $0.export.analyzePath.lowercased()] })
        let removals = (previous?.tracks ?? []).filter { old in
            let kept = ids[old.key] != nil
            return !kept || old.stickPath != stickPaths[old.key] || old.analyzePath != analyzePaths[old.key]
        }.map { CDJExportPlan.Removal(stickPath: $0.stickPath, analyzePath: $0.analyzePath) }
            .filter { !keptPaths.contains($0.stickPath.lowercased()) }

        let manifest = CDJExportManifest(
            libraryID: libraryID, nextTrackID: nextTrackID, nextPlaylistID: nextPlaylistID,
            tracks: records, playlists: playlistRecords)
        var plan = CDJExportPlan(
            items: items, playlists: playlists, missing: missing, unsupported: unsupported, manifest: manifest)
        plan.root = root
        plan.previous = previous
        plan.removals = removals
        return plan
    }

    /// Writes `plan` to the stick mounted at `volume`.
    public static func export(
        _ plan: CDJExportPlan,
        to volume: URL,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> CDJExportResult {
        try await export(plan, to: volume, environment: .live, progress: progress)
    }

    static func export(
        _ plan: CDJExportPlan,
        to volume: URL,
        environment: CDJExportEnvironment,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> CDJExportResult {
        if environment.requireVolumePath, !volume.standardizedFileURL.path.hasPrefix("/Volumes/") {
            throw CDJExportError.notAVolume(volume)
        }
        guard !plan.items.isEmpty else { throw CDJExportError.nothingToExport }
        let format = environment.detectFormat(volume)
        if let problem = format.blockingProblem { throw CDJExportError.unusableFormat(problem) }

        let publication = CDJExportPublication(volume: volume)
        let recovered = try publication.recoverInterruptedPublication()

        // The plan was made against a particular stick; make sure it is still that stick.
        let root = try CDJExportRoot.select(on: volume, format: format)
        let onStick = CDJExportManifest.load(from: volume, root: root)
        guard root == plan.root, onStick == plan.previous else { throw CDJExportError.stickChanged }

        let fileManager = FileManager.default
        let previousByKey = Dictionary(
            (plan.previous?.tracks ?? []).map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
        func audioIsCurrent(_ item: CDJExportPlan.Item) -> Bool {
            guard let old = previousByKey[item.key], old.stickPath == item.export.stickPath,
                  old.sourceSize == item.export.fileSize, old.sourceModified == item.sourceModified else { return false }
            let copy = volume.appendingPathComponent(String(item.export.stickPath.dropFirst()))
            return ((try? copy.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1) == old.copySize
        }
        func analysisIsCurrent(_ item: CDJExportPlan.Item) -> Bool {
            guard audioIsCurrent(item), previousByKey[item.key]?.analyzePath == item.export.analyzePath else { return false }
            let dat = volume.appendingPathComponent(String(item.export.analyzePath.dropFirst()))
            let ext = dat.deletingPathExtension().appendingPathExtension("EXT")
            return fileManager.fileExists(atPath: dat.path) && fileManager.fileExists(atPath: ext.path)
        }

        let needed = plan.items.filter { !audioIsCurrent($0) }.reduce(0) { $0 + $1.export.fileSize }
            + plan.items.count * 600_000 + 16_000_000  // analysis files and some headroom
        let free = environment.freeBytes(volume)
        guard needed <= free else { throw CDJExportError.notEnoughSpace(needed: needed, available: free) }

        // Stage everything new; nothing on the stick is touched yet.
        try publication.prepare()
        var placements: [String] = []
        var copied = 0
        var reused = 0
        var analysed = 0
        var withoutAnalysis = 0
        do {
            for (index, item) in plan.items.enumerated() {
                try Task.checkCancellation()
                let audioRelative = String(item.export.stickPath.dropFirst())
                if audioIsCurrent(item) {
                    reused += 1
                } else {
                    let staged = publication.stagedURL(audioRelative)
                    try fileManager.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fileManager.copyItem(at: item.source, to: staged)
                    placements.append(audioRelative)
                    copied += 1
                }
                if !analysisIsCurrent(item) {
                    let hadSeratoData = try await writeAnalysis(
                        for: item, into: publication.stage, placements: &placements)
                    if hadSeratoData { analysed += 1 } else { withoutAnalysis += 1 }
                }
                progress?(index + 1, plan.items.count)
            }

            let database = RekordboxPDBWriter.build(
                tracks: plan.items.map(\.export), playlists: plan.playlists,
                deviceName: volume.lastPathComponent, createdDate: dateString(Date()),
                libraryID: plan.manifest.libraryID)
            let databaseRelative = databasePath(root: plan.root)
            let manifestRelative = CDJExportManifest.relativePath(root: plan.root)
            try writeStaged(database, relative: databaseRelative, in: publication)
            try writeStaged(try plan.manifest.encoded(), relative: manifestRelative, in: publication)

            let removalPaths = removalRelativePaths(plan.removals)
            try RekordboxExportVerifier.verify(
                database: database, plan: plan,
                analysis: { path in
                    let relative = String(path.dropFirst())
                    let candidates = [publication.stagedURL(relative), volume.appendingPathComponent(relative)]
                    return candidates.lazy.compactMap { try? Data(contentsOf: $0) }.first
                },
                fileExists: { path in
                    let relative = String(path.dropFirst())
                    return !removalPaths.contains(relative)
                        && (fileManager.fileExists(atPath: publication.stagedURL(relative).path)
                            || fileManager.fileExists(atPath: volume.appendingPathComponent(relative).path))
                })

            // Last chance to back out cleanly, and a check the stick didn't change meanwhile.
            try Task.checkCancellation()
            guard CDJExportManifest.load(from: volume, root: plan.root) == plan.previous else {
                throw CDJExportError.stickChanged
            }

            // The databases go last, so a stick never points at files that aren't there yet.
            let journal = CDJExportPublication.Journal(
                placements: placements + [databaseRelative, manifestRelative],
                removals: removalPaths.sorted())
            try publication.commit(journal)
            do {
                let published = try Data(contentsOf: volume.appendingPathComponent(databaseRelative))
                _ = try RekordboxPDBFile(published).rowOffsets(inTable: RekordboxPDBWriter.TableType.tracks)
            } catch {
                try? publication.abandon(journal)
                throw CDJExportError.verificationFailed("The published database couldn't be read back.")
            }
            publication.pruneEmptyFolders(after: journal, stopAt: ["Contents", "USBANLZ", "PIONEER", ".PIONEER"])
            publication.finish()
        } catch {
            // Undo anything half-published. If that fails the backups are kept, and the
            // next run finishes the job, rather than deleting the only copy of the old files.
            _ = try? publication.recoverInterruptedPublication()
            throw error
        }

        return CDJExportResult(
            tracksWritten: plan.items.count, filesCopied: copied, filesAlreadyOnStick: reused,
            playlistCount: plan.playlists.filter { !$0.isFolder }.count,
            analysisFilesWritten: analysed, tracksWithoutSeratoAnalysis: withoutAnalysis,
            tracksRemoved: plan.removals.count, recoveredInterruptedExport: recovered)
    }

    /// Writes the track's ANLZ files into the stage. Returns whether Serato had any
    /// cues, loops or beatgrid for the track.
    static func writeAnalysis(
        for item: CDJExportPlan.Item, into stage: URL, placements: inout [String]
    ) async throws -> Bool {
        let seratoAnalysis = SeratoAnalysisTagReader.analysis(forFileAt: item.source)
        let durationMs = item.export.durationSeconds * 1000
        // A track we can't draw a waveform for still gets its cues and beat grid.
        let waveform = try? await AudioWaveformSampler.waveform(
            forFileAt: item.source, resolution: .perSecond(Double(RekordboxAnalysisWriter.scrollColumnsPerSecond)))
        let input = CDJAnalysisInput(
            stickPath: item.export.stickPath,
            durationMs: waveform.map { Int($0.duration * 1000) } ?? durationMs,
            beats: RekordboxAnalysisWriter.beats(from: seratoAnalysis?.beatgrid ?? [], durationMs: durationMs),
            analysis: seratoAnalysis ?? SeratoTrackAnalysis(),
            peaks: waveform?.peaks ?? [])

        let datRelative = String(item.export.analyzePath.dropFirst())
        let extRelative = String(datRelative.dropLast(3)) + "EXT"
        for (relative, data) in [
            (datRelative, RekordboxAnalysisWriter.datFile(input)),
            (extRelative, RekordboxAnalysisWriter.extFile(input))
        ] {
            let url = stage.appendingPathComponent(relative)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
            placements.append(relative)
        }
        return seratoAnalysis?.isEmpty == false
    }

    // MARK: - Helpers

    private static func writeStaged(_ data: Data, relative: String, in publication: CDJExportPublication) throws {
        let url = publication.stagedURL(relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// The stick files an export's removals delete: each audio file and its analysis pair.
    private static func removalRelativePaths(_ removals: [CDJExportPlan.Removal]) -> Set<String> {
        var paths = Set<String>()
        for removal in removals {
            paths.insert(String(removal.stickPath.dropFirst()))
            let dat = String(removal.analyzePath.dropFirst())
            paths.insert(dat)
            paths.insert(String(dat.dropLast(3)) + "EXT")
        }
        return paths
    }

    private static func sameExtension(_ stickPath: String, _ track: Track) -> Bool {
        (stickPath as NSString).pathExtension.lowercased() == track.fileURL.pathExtension.lowercased()
    }

    /// `/Contents/Artist/Album/File.ext`, made safe for FAT32 and unique within the export.
    static func uniqueStickPath(for track: Track, used: inout Set<String>) -> String {
        let artist = sanitize(track.artist, fallback: "Unknown Artist")
        let album = sanitize(track.album, fallback: "Unknown Album")
        let ext = track.fileURL.pathExtension
        let base = sanitize(track.fileURL.deletingPathExtension().lastPathComponent, fallback: "Track")
        var candidate = "/Contents/\(artist)/\(album)/\(base).\(ext)"
        var counter = 2
        while !used.insert(candidate.lowercased()).inserted {
            candidate = "/Contents/\(artist)/\(album)/\(base) (\(counter)).\(ext)"
            counter += 1
        }
        return candidate
    }

    /// `/a/b/file.mp3` with `suffix` added to the file's name before its extension.
    static func withSuffix(_ suffix: String, to path: String) -> String {
        let url = URL(fileURLWithPath: path)
        let stem = url.deletingPathExtension().lastPathComponent
        let name = url.pathExtension.isEmpty ? stem + suffix : "\(stem)\(suffix).\(url.pathExtension)"
        return url.deletingLastPathComponent().appendingPathComponent(name).path
    }

    static func sanitize(_ name: String, fallback: String) -> String {
        let illegal = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        var cleaned = name.components(separatedBy: illegal).joined(separator: "_")
            .trimmingCharacters(in: CharacterSet(charactersIn: " .")
            )
        if cleaned.count > 80 { cleaned = String(cleaned.prefix(80)).trimmingCharacters(in: .whitespaces) }
        return cleaned.isEmpty ? fallback : cleaned
    }

    private static func dateString(_ date: Date?) -> String {
        guard let date else { return "" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: date)
    }
}
