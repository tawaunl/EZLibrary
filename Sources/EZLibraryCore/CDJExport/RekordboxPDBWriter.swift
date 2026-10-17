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

/// A track as the CDJ database describes it. Paths are the on-stick paths
/// (`/Contents/Artist/Album/file.mp3`), not paths on the Mac.
public struct CDJExportTrack: Sendable, Equatable {
    public var id: UInt32
    public var title: String
    public var artist: String
    public var album: String
    public var genre: String
    public var label: String
    public var comment: String
    public var year: Int
    public var durationSeconds: Int
    public var bpm: Double
    public var bitrate: Int
    public var sampleRate: Int
    public var fileSize: Int
    public var trackNumber: Int
    public var fileType: CDJFileType
    public var stickPath: String
    public var dateAdded: String
    /// `/PIONEER/USBANLZ/…/ANLZ0000.DAT` for this track, or empty when it has no analysis files.
    public var analyzePath: String

    public init(
        id: UInt32, title: String, artist: String = "", album: String = "",
        genre: String = "", label: String = "", comment: String = "",
        year: Int = 0, durationSeconds: Int = 0, bpm: Double = 0,
        bitrate: Int = 0, sampleRate: Int = 44_100, fileSize: Int = 0,
        trackNumber: Int = 0, fileType: CDJFileType = .mp3,
        stickPath: String, dateAdded: String = "", analyzePath: String = ""
    ) {
        self.id = id
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.label = label
        self.comment = comment
        self.year = year
        self.durationSeconds = durationSeconds
        self.bpm = bpm
        self.bitrate = bitrate
        self.sampleRate = sampleRate
        self.fileSize = fileSize
        self.trackNumber = trackNumber
        self.fileType = fileType
        self.stickPath = stickPath
        self.dateAdded = dateAdded
        self.analyzePath = analyzePath
    }

    public var fileName: String {
        (stickPath as NSString).lastPathComponent
    }
}

/// The `file_type` codes the Pioneer database uses.
public enum CDJFileType: UInt16, Sendable {
    case mp3 = 1
    case m4a = 4
    case flac = 5
    case wav = 11
    case aiff = 12

    public init?(pathExtension: String) {
        switch pathExtension.lowercased() {
        case "mp3": self = .mp3
        case "m4a", "aac", "mp4": self = .m4a
        case "flac": self = .flac
        case "wav": self = .wav
        case "aif", "aiff": self = .aiff
        default: return nil
        }
    }
}

/// A playlist (a Serato crate) or a folder of playlists (a crate with
/// sub-crates) in the CDJ browser.
public struct CDJExportPlaylist: Sendable, Equatable {
    public var id: UInt32
    public var parentID: UInt32
    public var name: String
    public var isFolder: Bool
    public var sortOrder: UInt32
    public var trackIDs: [UInt32]

    public init(
        id: UInt32, parentID: UInt32 = 0, name: String, isFolder: Bool = false,
        sortOrder: UInt32 = 0, trackIDs: [UInt32] = []
    ) {
        self.id = id
        self.parentID = parentID
        self.name = name
        self.isFolder = isFolder
        self.sortOrder = sortOrder
        self.trackIDs = trackIDs
    }
}

/// Writes the `export.pdb` file that Pioneer/AlphaTheta players read from
/// `PIONEER/rekordbox/` on a USB stick.
///
/// The format is the undocumented "DeviceSQL" page database, as reverse
/// engineered by the Deep Symmetry (crate-digger) and rekordcrate projects.
/// It is a fixed-size-page file: page 0 lists the tables, and each table is
/// one index page followed by data pages holding rows. This writer covers
/// tracks, artists, albums, genres, labels, playlists and playlist entries;
/// the remaining tables are written empty.
///
/// This has been checked only against the published format descriptions and
/// our own reader in the tests, not against real hardware.
public enum RekordboxPDBWriter {
    static let pageSize = 4096
    static let pageHeaderSize = 0x28
    static let rowGroupSize = 0x24
    static let tableCount = 20

    enum TableType: UInt32 {
        case tracks = 0, genres, artists, albums, labels, keys, colors
        case playlistTree, playlistEntries
    }

    public static func build(tracks: [CDJExportTrack], playlists: [CDJExportPlaylist]) -> Data {
        var names = NameTables()
        var trackRows: [Data] = []
        for track in tracks.sorted(by: { $0.id < $1.id }) {
            let artistID = names.artistID(track.artist)
            let albumID = names.albumID(track.album, artistID: artistID)
            let genreID = names.genreID(track.genre)
            let labelID = names.labelID(track.label)
            trackRows.append(trackRow(
                track, artistID: artistID, albumID: albumID, genreID: genreID, labelID: labelID))
        }

        var tableRows: [UInt32: [Data]] = [:]
        tableRows[TableType.tracks.rawValue] = trackRows
        tableRows[TableType.genres.rawValue] = names.genres.map { idNameRow(id: $0.id, name: $0.name) }
        tableRows[TableType.labels.rawValue] = names.labels.map { idNameRow(id: $0.id, name: $0.name) }
        tableRows[TableType.artists.rawValue] = names.artists.enumerated().map {
            artistRow(id: $0.element.id, name: $0.element.name, index: $0.offset)
        }
        tableRows[TableType.albums.rawValue] = names.albums.enumerated().map {
            albumRow(id: $0.element.id, artistID: $0.element.artistID, name: $0.element.name, index: $0.offset)
        }
        tableRows[TableType.playlistTree.rawValue] = playlists.sorted { $0.id < $1.id }.map(playlistTreeRow)
        var entryRows: [Data] = []
        for playlist in playlists where !playlist.isFolder {
            for (index, trackID) in playlist.trackIDs.enumerated() {
                entryRows.append(playlistEntryRow(
                    entryIndex: UInt32(index + 1), trackID: trackID, playlistID: playlist.id))
            }
        }
        tableRows[TableType.playlistEntries.rawValue] = entryRows

        return assemble(tableRows: tableRows)
    }

    // MARK: - File and page layout

    private static func assemble(tableRows: [UInt32: [Data]]) -> Data {
        struct Layout {
            var firstPage: UInt32 = 0
            var lastPage: UInt32 = 0
            var emptyCandidate: UInt32 = 0
        }
        var pages: [Data] = [Data(count: pageSize)]  // page 0 is filled in last
        var layouts: [Layout] = []
        // Index and data pages are finished after every table's extent is known.
        var pendingIndexPages: [(table: UInt32, indexPage: UInt32, dataPages: [UInt32])] = []

        for table in 0..<UInt32(tableCount) {
            let packed = packPages(rows: tableRows[table] ?? [])
            let indexPageNumber = UInt32(pages.count)
            let firstDataPage = indexPageNumber + 1
            let dataPageNumbers = (0..<UInt32(packed.count)).map { firstDataPage + $0 }
            pages.append(Data(count: pageSize))  // index page, filled in below
            pages.append(contentsOf: packed)
            layouts.append(Layout(
                firstPage: indexPageNumber,
                lastPage: dataPageNumbers.last ?? indexPageNumber))
            pendingIndexPages.append((table, indexPageNumber, dataPageNumbers))
        }

        let nextUnused = UInt32(pages.count) + UInt32(tableCount)
        for index in 0..<tableCount {
            layouts[index].emptyCandidate = UInt32(pages.count) + UInt32(index)
        }
        // Reserve one blank page per table for the "next free page" pointer.
        for _ in 0..<tableCount { pages.append(Data(count: pageSize)) }

        for (table, indexPage, dataPages) in pendingIndexPages {
            let empty = layouts[Int(table)].emptyCandidate
            for (position, pageNumber) in dataPages.enumerated() {
                let next = position + 1 < dataPages.count ? dataPages[position + 1] : empty
                finalizeDataPage(&pages[Int(pageNumber)], pageNumber: pageNumber, table: table, next: next)
            }
            pages[Int(indexPage)] = indexPageData(
                pageNumber: indexPage, table: table,
                next: dataPages.first ?? empty, dataPages: dataPages)
        }

        var header = Data()
        header.appendLE(UInt32(0))
        header.appendLE(UInt32(pageSize))
        header.appendLE(UInt32(tableCount))
        header.appendLE(nextUnused)
        header.appendLE(UInt32(5))
        header.appendLE(UInt32(1))
        header.appendLE(UInt32(0))
        for (table, layout) in layouts.enumerated() {
            header.appendLE(UInt32(table))
            header.appendLE(layout.emptyCandidate)
            header.appendLE(layout.firstPage)
            header.appendLE(layout.lastPage)
        }
        header.append(Data(count: pageSize - header.count))
        pages[0] = header

        return pages.reduce(into: Data()) { $0.append($1) }
    }

    /// Packs rows into data pages. Each page's header is completed later, once
    /// its page number and successor are known.
    private static func packPages(rows: [Data]) -> [Data] {
        var pages: [Data] = []
        var current: [Data] = []
        var heapUsed = 0

        func capacityNeeded(rowCount: Int, heap: Int) -> Int {
            let groups = (rowCount + 15) / 16
            return pageHeaderSize + heap + groups * rowGroupSize
        }
        func flush() {
            guard !current.isEmpty else { return }
            pages.append(dataPageBody(rows: current))
            current = []
            heapUsed = 0
        }

        for row in rows {
            if capacityNeeded(rowCount: current.count + 1, heap: heapUsed + row.count) > pageSize {
                flush()
            }
            current.append(row)
            heapUsed += row.count
        }
        flush()
        return pages
    }

    /// A data page with its heap and row index filled in; the header fields
    /// that depend on neighbours are set by `finalizeDataPage`.
    private static func dataPageBody(rows: [Data]) -> Data {
        var page = Data(count: pageSize)
        var heapOffset = 0
        var offsets: [Int] = []
        for row in rows {
            page.replaceSubrange(
                (pageHeaderSize + heapOffset)..<(pageHeaderSize + heapOffset + row.count), with: row)
            offsets.append(heapOffset)
            heapOffset += row.count
        }
        for (group, start) in stride(from: 0, to: rows.count, by: 16).enumerated() {
            let flagsPos = pageSize - group * rowGroupSize - 4
            var presence: UInt16 = 0
            for slot in 0..<min(16, rows.count - start) {
                page.writeLE(UInt16(offsets[start + slot]), at: flagsPos - 2 * (slot + 1))
                presence |= 1 << UInt16(slot)
            }
            page.writeLE(presence, at: flagsPos)
            page.writeLE(UInt16(0), at: flagsPos + 2)
        }
        let groups = (rows.count + 15) / 16
        let free = pageSize - pageHeaderSize - heapOffset - groups * rowGroupSize
        page[0x18] = UInt8(truncatingIfNeeded: rows.count)
        page[0x1b] = 0x34
        page.writeLE(UInt16(free), at: 0x1c)
        page.writeLE(UInt16(heapOffset), at: 0x1e)
        page.writeLE(UInt16(rows.count), at: 0x22)
        return page
    }

    private static func finalizeDataPage(_ page: inout Data, pageNumber: UInt32, table: UInt32, next: UInt32) {
        page.writeLE(UInt32(0), at: 0x00)
        page.writeLE(pageNumber, at: 0x04)
        page.writeLE(table, at: 0x08)
        page.writeLE(next, at: 0x0c)
        page.writeLE(UInt32(1), at: 0x10)
    }

    private static func indexPageData(pageNumber: UInt32, table: UInt32, next: UInt32, dataPages: [UInt32]) -> Data {
        var page = Data(count: pageSize)
        page.writeLE(pageNumber, at: 0x04)
        page.writeLE(table, at: 0x08)
        page.writeLE(next, at: 0x0c)
        page.writeLE(UInt32(1), at: 0x10)
        page[0x1b] = 0x64
        page.writeLE(UInt16(0x1fff), at: 0x28)
        page.writeLE(UInt16(0x1fff), at: 0x2a)
        page.writeLE(UInt16(0x03ec), at: 0x2c)
        page.writeLE(pageNumber, at: 0x30)
        page.writeLE(next, at: 0x34)
        page.writeLE(UInt32(0x03ff_ffff), at: 0x38)
        // Index entries: (page << 3) per data page, the rest marked unused.
        let entriesStart = 0x44
        let capacity = (pageSize - entriesStart) / 4
        for slot in 0..<capacity {
            let value: UInt32 = slot < dataPages.count ? dataPages[slot] << 3 : 0x1fff_ffff
            page.writeLE(value, at: entriesStart + slot * 4)
        }
        return page
    }

    // MARK: - Rows

    private static func trackRow(
        _ track: CDJExportTrack, artistID: UInt32, albumID: UInt32, genreID: UInt32, labelID: UInt32
    ) -> Data {
        let headerSize = 0x5E + 21 * 2
        var row = Data(count: headerSize)
        row.writeLE(UInt16(0x24), at: 0x00)
        row.writeLE(UInt16(truncatingIfNeeded: Int(track.id - 1) * 0x20), at: 0x02)
        row.writeLE(UInt32(0x000c_0700), at: 0x04)
        row.writeLE(UInt32(track.sampleRate), at: 0x08)
        row.writeLE(UInt32(track.fileSize), at: 0x10)
        row.writeLE(UInt32(2), at: 0x14)
        row.writeLE(labelID, at: 0x28)
        row.writeLE(UInt32(track.bitrate), at: 0x30)
        row.writeLE(UInt32(track.trackNumber), at: 0x34)
        row.writeLE(UInt32((track.bpm * 100).rounded()), at: 0x38)
        row.writeLE(genreID, at: 0x3c)
        row.writeLE(albumID, at: 0x40)
        row.writeLE(artistID, at: 0x44)
        row.writeLE(track.id, at: 0x48)
        row.writeLE(UInt16(clamping: track.year), at: 0x50)
        row.writeLE(UInt16(16), at: 0x52)
        row.writeLE(UInt16(clamping: track.durationSeconds), at: 0x54)
        row.writeLE(UInt16(41), at: 0x56)
        row.writeLE(track.fileType.rawValue, at: 0x5a)
        row.writeLE(UInt16(3), at: 0x5c)

        // 21 string slots; only some carry data, the rest point at an empty string.
        var strings = [String](repeating: "", count: 21)
        if !track.analyzePath.isEmpty {
            strings[7] = "ON"
            strings[14] = track.analyzePath
            strings[15] = track.dateAdded
        }
        strings[10] = track.dateAdded
        strings[11] = track.dateAdded
        strings[16] = track.comment
        strings[17] = track.title
        strings[19] = track.fileName
        strings[20] = track.stickPath
        for (slot, value) in strings.enumerated() {
            row.writeLE(UInt16(row.count), at: 0x5E + slot * 2)
            row.append(DeviceSQLString.encode(value))
        }
        return padded(row)
    }

    private static func artistRow(id: UInt32, name: String, index: Int) -> Data {
        var row = Data()
        row.appendLE(UInt16(0x60))
        row.appendLE(UInt16(truncatingIfNeeded: index * 0x20))
        row.appendLE(id)
        row.append(0x03)
        row.append(0x0a)
        row.append(DeviceSQLString.encode(name))
        return padded(row)
    }

    private static func albumRow(id: UInt32, artistID: UInt32, name: String, index: Int) -> Data {
        var row = Data()
        row.appendLE(UInt16(0x80))
        row.appendLE(UInt16(truncatingIfNeeded: index * 0x20))
        row.appendLE(UInt32(0))
        row.appendLE(artistID)
        row.appendLE(id)
        row.appendLE(UInt32(0))
        row.append(0x03)
        row.append(0x16)
        row.append(DeviceSQLString.encode(name))
        return padded(row)
    }

    private static func idNameRow(id: UInt32, name: String) -> Data {
        var row = Data()
        row.appendLE(id)
        row.append(DeviceSQLString.encode(name))
        return padded(row)
    }

    private static func playlistTreeRow(_ playlist: CDJExportPlaylist) -> Data {
        var row = Data()
        row.appendLE(playlist.parentID)
        row.appendLE(UInt32(0))
        row.appendLE(playlist.sortOrder)
        row.appendLE(playlist.id)
        row.appendLE(UInt32(playlist.isFolder ? 1 : 0))
        row.append(DeviceSQLString.encode(playlist.name))
        return padded(row)
    }

    private static func playlistEntryRow(entryIndex: UInt32, trackID: UInt32, playlistID: UInt32) -> Data {
        var row = Data()
        row.appendLE(entryIndex)
        row.appendLE(trackID)
        row.appendLE(playlistID)
        return row
    }

    private static func padded(_ row: Data) -> Data {
        var row = row
        while row.count % 4 != 0 { row.append(0) }
        return row
    }

    // MARK: - Deduplicated lookup tables

    private struct NameTables {
        struct Named { var id: UInt32; var name: String }
        struct Album { var id: UInt32; var artistID: UInt32; var name: String }
        var artists: [Named] = []
        var genres: [Named] = []
        var labels: [Named] = []
        var albums: [Album] = []

        mutating func artistID(_ name: String) -> UInt32 { Self.id(for: name, in: &artists) }
        mutating func genreID(_ name: String) -> UInt32 { Self.id(for: name, in: &genres) }
        mutating func labelID(_ name: String) -> UInt32 { Self.id(for: name, in: &labels) }

        mutating func albumID(_ name: String, artistID: UInt32) -> UInt32 {
            guard !name.isEmpty else { return 0 }
            if let hit = albums.first(where: { $0.name == name && $0.artistID == artistID }) { return hit.id }
            let id = UInt32(albums.count + 1)
            albums.append(Album(id: id, artistID: artistID, name: name))
            return id
        }

        private static func id(for name: String, in list: inout [Named]) -> UInt32 {
            guard !name.isEmpty else { return 0 }
            if let hit = list.first(where: { $0.name == name }) { return hit.id }
            let id = UInt32(list.count + 1)
            list.append(Named(id: id, name: name))
            return id
        }
    }
}

/// Pioneer's string encoding: a one-byte header for short ASCII, or a
/// length-prefixed UTF-16LE form for anything else.
enum DeviceSQLString {
    static func encode(_ value: String) -> Data {
        if value.isEmpty { return Data([0x03]) }
        if value.utf8.count <= 126, value.unicodeScalars.allSatisfy({ $0.isASCII }) {
            var data = Data([UInt8(((value.utf8.count + 1) << 1) | 1)])
            data.append(contentsOf: value.utf8)
            return data
        }
        let units = Array(value.utf16.prefix(8_000))
        var data = Data([0x90])
        data.appendLE(UInt16(units.count * 2 + 4))
        data.append(0x00)
        for unit in units { data.appendLE(unit) }
        return data
    }
}

extension Data {
    mutating func appendLE<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) { append(contentsOf: $0) }
    }

    mutating func writeLE<T: FixedWidthInteger>(_ value: T, at offset: Int) {
        var little = value.littleEndian
        Swift.withUnsafeBytes(of: &little) {
            replaceSubrange(offset..<(offset + MemoryLayout<T>.size), with: $0)
        }
    }
}
