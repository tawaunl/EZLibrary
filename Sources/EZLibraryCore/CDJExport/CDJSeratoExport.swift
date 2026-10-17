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
        public let source: URL
        public let export: CDJExportTrack
    }

    public var items: [Item]
    public var playlists: [CDJExportPlaylist]
    /// Tracks in the chosen crates whose audio file isn't on disk.
    public var missing: [Track]
    /// Tracks in a file type CDJs can't play.
    public var unsupported: [Track]

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
}

public enum CDJExportError: LocalizedError {
    case notAVolume(URL)
    case unusableFormat(String)
    case notEnoughSpace(needed: Int, available: Int)
    case nothingToExport

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
        }
    }

    public var recoverySuggestion: String? {
        switch self {
        case .notAVolume: return "Choose a drive under /Volumes."
        case .unusableFormat: return "Reformat the stick in Disk Utility, then try again."
        case .notEnoughSpace: return "Pick fewer crates or use a larger stick."
        case .nothingToExport: return "Pick crates that contain tracks."
        }
    }
}

/// Copies Serato crates onto a USB stick in the layout Pioneer CDJs and XDJs
/// browse: audio under `Contents/`, and a database at
/// `PIONEER/rekordbox/export.pdb` so each crate shows up as a playlist.
///
/// Read-only with respect to Serato: nothing in the library is modified.
/// Phase 1 writes tracks and playlists. Hot cues, beatgrids and waveforms
/// (the ANLZ analysis files) are not written yet, so decks analyse tracks on
/// load.
public enum CDJSeratoExport {
    static let databaseRelativePath = "PIONEER/rekordbox/export.pdb"

    /// Works out what an export would do, without touching the stick.
    public static func plan(crates: [Crate], library tracks: [Track]) -> CDJExportPlan {
        let byPath = Dictionary(tracks.map { ($0.seratoStoredPath, $0) }, uniquingKeysWith: { first, _ in first })
        let fileManager = FileManager.default

        var idsByPath: [String: UInt32] = [:]
        var items: [CDJExportPlan.Item] = []
        var missing: [Track] = []
        var unsupported: [Track] = []
        var usedStickPaths = Set<String>()

        func exportID(for track: Track) -> UInt32? {
            if let known = idsByPath[track.seratoStoredPath] { return known }
            guard let type = CDJFileType(pathExtension: track.fileURL.pathExtension) else {
                unsupported.append(track)
                return nil
            }
            guard fileManager.fileExists(atPath: track.fileURL.path) else {
                missing.append(track)
                return nil
            }
            let id = UInt32(idsByPath.count + 1)
            idsByPath[track.seratoStoredPath] = id
            let size = (try? track.fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            let stickPath = uniqueStickPath(for: track, used: &usedStickPaths)
            items.append(CDJExportPlan.Item(
                source: track.fileURL,
                export: CDJExportTrack(
                    id: id, title: track.title.isEmpty ? track.fileURL.deletingPathExtension().lastPathComponent : track.title,
                    artist: track.artist, album: track.album, genre: track.genre,
                    label: track.label, comment: track.comment, year: track.year ?? 0,
                    durationSeconds: Int(track.duration ?? 0), bpm: track.bpm ?? 0,
                    bitrate: Int(track.bitrate?.filter(\.isNumber) ?? "") ?? 0,
                    sampleRate: Int(track.sampleRate?.filter(\.isNumber) ?? "") ?? 44_100,
                    fileSize: size, trackNumber: track.trackNumber ?? 0, fileType: type,
                    stickPath: stickPath, dateAdded: dateString(track.dateAdded),
                    analyzePath: analyzePath(forTrackID: id))))
            return id
        }

        var playlists: [CDJExportPlaylist] = []
        var folderIDs: [[String]: UInt32] = [:]

        func nextPlaylistID() -> UInt32 { UInt32(playlists.count + 1) }

        for crate in crates.sorted(by: { $0.pathComponents.lexicographicallyPrecedes($1.pathComponents) }) {
            var parentID: UInt32 = 0
            for depth in 1..<max(crate.pathComponents.count, 1) {
                let path = Array(crate.pathComponents.prefix(depth))
                if let existing = folderIDs[path] {
                    parentID = existing
                } else {
                    let id = nextPlaylistID()
                    playlists.append(CDJExportPlaylist(
                        id: id, parentID: parentID, name: path[depth - 1], isFolder: true,
                        sortOrder: UInt32(playlists.count)))
                    folderIDs[path] = id
                    parentID = id
                }
            }
            let trackIDs = crate.trackPaths.compactMap { byPath[$0] }.compactMap(exportID)
            playlists.append(CDJExportPlaylist(
                id: nextPlaylistID(), parentID: parentID, name: crate.name,
                sortOrder: UInt32(playlists.count), trackIDs: trackIDs))
        }
        return CDJExportPlan(items: items, playlists: playlists, missing: missing, unsupported: unsupported)
    }

    /// Writes `plan` to the stick mounted at `volume`.
    public static func export(
        _ plan: CDJExportPlan,
        to volume: URL,
        progress: (@Sendable (Int, Int) -> Void)? = nil
    ) async throws -> CDJExportResult {
        guard volume.standardizedFileURL.path.hasPrefix("/Volumes/") else {
            throw CDJExportError.notAVolume(volume)
        }
        guard !plan.items.isEmpty else { throw CDJExportError.nothingToExport }
        let format = CDJStickFormat.detect(at: volume)
        if let problem = format.blockingProblem { throw CDJExportError.unusableFormat(problem) }

        let fileManager = FileManager.default
        let free = (try? volume.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity) ?? Int.max
        let needed = plan.items.filter { !alreadyOnStick($0, volume: volume) }.reduce(0) { $0 + $1.export.fileSize }
        guard needed <= free else { throw CDJExportError.notEnoughSpace(needed: needed, available: free) }

        var copied = 0
        var skipped = 0
        var analysed = 0
        var withoutAnalysis = 0
        for (index, item) in plan.items.enumerated() {
            let destination = volume.appendingPathComponent(String(item.export.stickPath.dropFirst()))
            if alreadyOnStick(item, volume: volume) {
                skipped += 1
            } else {
                try fileManager.createDirectory(
                    at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                if fileManager.fileExists(atPath: destination.path) { try fileManager.removeItem(at: destination) }
                try fileManager.copyItem(at: item.source, to: destination)
                copied += 1
            }
            if try await writeAnalysis(for: item, volume: volume) {
                analysed += 1
            } else {
                withoutAnalysis += 1
            }
            progress?(index + 1, plan.items.count)
        }

        // Database goes last: a stick interrupted mid-copy keeps its old
        // database rather than pointing at files that aren't there yet.
        let database = RekordboxPDBWriter.build(tracks: plan.items.map(\.export), playlists: plan.playlists)
        let databaseURL = volume.appendingPathComponent(databaseRelativePath)
        try fileManager.createDirectory(at: databaseURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFileWriter.write(database, to: databaseURL)

        return CDJExportResult(
            tracksWritten: plan.items.count, filesCopied: copied, filesAlreadyOnStick: skipped,
            playlistCount: plan.playlists.filter { !$0.isFolder }.count,
            analysisFilesWritten: analysed, tracksWithoutSeratoAnalysis: withoutAnalysis)
    }

    /// Writes the track's ANLZ files. Returns whether Serato had any cues, loops or beatgrid for the track.
    static func writeAnalysis(for item: CDJExportPlan.Item, volume: URL) async throws -> Bool {
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

        let datURL = volume.appendingPathComponent(String(item.export.analyzePath.dropFirst()))
        let extURL = datURL.deletingPathExtension().appendingPathExtension("EXT")
        try FileManager.default.createDirectory(at: datURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try AtomicFileWriter.write(RekordboxAnalysisWriter.datFile(input), to: datURL)
        try AtomicFileWriter.write(RekordboxAnalysisWriter.extFile(input), to: extURL)
        return seratoAnalysis?.isEmpty == false
    }

    /// Where a track's ANLZ files go: unique per track, in rekordbox's `Pxxx/xxxxxxxx` layout.
    static func analyzePath(forTrackID id: UInt32) -> String {
        String(format: "/PIONEER/USBANLZ/P%03X/%08X/ANLZ0000.DAT", Int(id >> 8) & 0xFFF, id)
    }

    // MARK: - Helpers

    private static func alreadyOnStick(_ item: CDJExportPlan.Item, volume: URL) -> Bool {
        let destination = volume.appendingPathComponent(String(item.export.stickPath.dropFirst()))
        let size = (try? destination.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? -1
        return size == item.export.fileSize
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
