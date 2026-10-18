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
/// The format is the undocumented "DeviceSQL" page database. The layout here
/// follows the evidence-labelled reference in the rbxport project
/// (`docs/reference/usb-export-db.md`), which was checked against
/// rekordbox 7 exports. It is a fixed-size-page file: page 0 lists the
/// tables, and each table is one index page followed by data pages of rows.
///
/// Checked against that reference and our own reader in the tests, not
/// against real hardware.
public enum RekordboxPDBWriter {
    static let pageSize = 4096
    static let pageHeaderSize = 0x28
    static let rowGroupSize = 0x24
    static let tableCount = 20
    /// The value an index page names in place of a first data page when its table has none.
    static let noPage: UInt32 = 0x03ff_ffff

    enum TableType {
        static let tracks: UInt32 = 0
        static let genres: UInt32 = 1
        static let artists: UInt32 = 2
        static let albums: UInt32 = 3
        static let labels: UInt32 = 4
        static let keys: UInt32 = 5
        static let colors: UInt32 = 6
        static let playlistTree: UInt32 = 7
        static let playlistEntries: UInt32 = 8
        static let columns: UInt32 = 16
        static let categorySettings: UInt32 = 17
        static let sortSettings: UInt32 = 18
        static let property: UInt32 = 19
    }

    /// Tables whose rows open with a u16 subtype and carry their on-page slot
    /// (times 32) in the next u16.
    private static let slottedTables: Set<UInt32> = [
        TableType.tracks, TableType.artists, TableType.albums, TableType.property
    ]

    public static func build(
        tracks: [CDJExportTrack],
        playlists: [CDJExportPlaylist],
        deviceName: String = "",
        createdDate: String = "1970-01-01",
        libraryID: UInt32 = 1
    ) -> Data {
        var names = NameTables()
        var trackRows: [Data] = []
        for track in tracks.sorted(by: { $0.id < $1.id }) {
            let artistID = names.artistID(track.artist)
            let albumID = names.albumID(track.album, artistID: artistID)
            let genreID = names.genreID(track.genre)
            let labelID = names.labelID(track.label)
            trackRows.append(trackRow(
                track, artistID: artistID, albumID: albumID, genreID: genreID,
                labelID: labelID, libraryID: libraryID))
        }

        var tableRows: [UInt32: [Data]] = [:]
        tableRows[TableType.tracks] = trackRows
        tableRows[TableType.genres] = names.genres.map { idNameRow(id: $0.id, name: $0.name) }
        tableRows[TableType.labels] = names.labels.map { idNameRow(id: $0.id, name: $0.name) }
        tableRows[TableType.artists] = names.artists.map { artistRow(id: $0.id, name: $0.name) }
        tableRows[TableType.albums] = names.albums.map {
            albumRow(id: $0.id, artistID: $0.artistID, name: $0.name)
        }
        tableRows[TableType.colors] = colorNames.enumerated().map { colorRow(id: UInt16($0.offset + 1), name: $0.element) }
        tableRows[TableType.playlistTree] = playlists.sorted { $0.id < $1.id }.map(playlistTreeRow)
        var entryRows: [Data] = []
        for playlist in playlists where !playlist.isFolder {
            for (index, trackID) in playlist.trackIDs.enumerated() {
                entryRows.append(playlistEntryRow(
                    entryIndex: UInt32(index + 1), trackID: trackID, playlistID: playlist.id))
            }
        }
        tableRows[TableType.playlistEntries] = entryRows
        tableRows[TableType.columns] = RekordboxFixedRows.columns
        tableRows[TableType.categorySettings] = RekordboxFixedRows.categorySettings
        tableRows[TableType.sortSettings] = RekordboxFixedRows.sortSettings
        tableRows[TableType.property] = [propertyRow(
            contents: tracks.count, createdDate: createdDate, deviceName: deviceName)]

        return assemble(tableRows: tableRows)
    }

    private static let colorNames = ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"]

    // MARK: - File layout

    /// Lays the file out the way rekordbox does: the header page; then every
    /// table's index page followed by its first data page (or, for an empty
    /// table, one zeroed page the header names as its empty candidate); then
    /// each table's remaining pages and its empty candidate in write order,
    /// `property` first.
    private static func assemble(tableRows: [UInt32: [Data]]) -> Data {
        struct Entry {
            var type: UInt32
            var first: UInt32
            var last: UInt32
            var candidate: UInt32
        }
        var pages: [Data] = []
        var entries: [Entry] = []
        var nextIndex: UInt32 = 1
        var sequence: UInt32 = 1
        var held: [(entry: Int, rest: [Data])] = []

        func append(_ page: Data) -> UInt32 {
            pages.append(page)
            defer { nextIndex += 1 }
            return nextIndex
        }

        for type in 0..<UInt32(tableCount) {
            let rows = tableRows[type] ?? []
            let indexAt = nextIndex
            if rows.isEmpty {
                let candidate = indexAt + 1
                _ = append(indexPage(index: indexAt, type: type, next: candidate, firstDataPage: nil))
                _ = append(Data(count: pageSize))
                entries.append(Entry(type: type, first: indexAt, last: indexAt, candidate: candidate))
            } else {
                var dataPages = paginate(rows, slotted: slottedTables.contains(type))
                let firstData = indexAt + 1
                _ = append(indexPage(index: indexAt, type: type, next: firstData, firstDataPage: firstData))
                var first = dataPages.removeFirst()
                first.writeLE(firstData, at: 0x04)
                first.writeLE(type, at: 0x08)
                _ = append(first)
                entries.append(Entry(type: type, first: indexAt, last: firstData, candidate: .max))
                held.append((entries.count - 1, dataPages))
            }
        }

        // `property` is written first; the rest follow in table order.
        held.sort { lhs, rhs in
            func rank(_ entry: Int) -> (Int, UInt32) {
                entries[entry].type == TableType.property ? (0, 0) : (1, entries[entry].type)
            }
            return rank(lhs.entry) < rank(rhs.entry)
        }
        for (entryAt, rest) in held {
            let type = entries[entryAt].type
            var lastPage = Int(entries[entryAt].last) - 1
            sequence += 1
            pages[lastPage].writeLE(sequence, at: 0x10)
            for var page in rest {
                let index = nextIndex
                page.writeLE(index, at: 0x04)
                page.writeLE(type, at: 0x08)
                sequence += 1
                page.writeLE(sequence, at: 0x10)
                pages[lastPage].writeLE(index, at: 0x0c)
                _ = append(page)
                lastPage = pages.count - 1
                entries[entryAt].last = index
            }
            let candidate = append(Data(count: pageSize))
            pages[lastPage].writeLE(candidate, at: 0x0c)
            entries[entryAt].candidate = candidate
        }

        // Trailing zeroed pages aren't written; the header still names them.
        while let last = pages.last, last.allSatisfy({ $0 == 0 }) { pages.removeLast() }

        var header = Data(count: pageSize)
        header.writeLE(UInt32(pageSize), at: 0x04)
        header.writeLE(UInt32(tableCount), at: 0x08)
        header.writeLE(nextIndex, at: 0x0c)
        header.writeLE(UInt32(1), at: 0x10)
        // One past every page's sequence: a player rolls back pages carrying the header's.
        header.writeLE(sequence + 1, at: 0x14)
        for (position, entry) in entries.enumerated() {
            let base = 0x1c + position * 16
            header.writeLE(entry.type, at: base)
            header.writeLE(entry.candidate, at: base + 4)
            header.writeLE(entry.first, at: base + 8)
            header.writeLE(entry.last, at: base + 12)
        }
        return pages.reduce(into: header) { $0.append($1) }
    }

    /// The page that heads every table: flags `0x64`, no rows, `0x1fff` in both
    /// row-count words, `0x03ec` at `0x24`, and a body naming itself and the
    /// first data page, then a run of `ff 1f f8 ff`. A file whose tables start
    /// with a plain data page is read as corrupted.
    static func indexPage(index: UInt32, type: UInt32, next: UInt32, firstDataPage: UInt32?) -> Data {
        var page = Data(count: pageSize)
        page.writeLE(index, at: 0x04)
        page.writeLE(type, at: 0x08)
        page.writeLE(next, at: 0x0c)
        page.writeLE(UInt32(1), at: 0x10)
        page[0x1b] = 0x64
        page.writeLE(UInt16(0x1fff), at: 0x20)
        page.writeLE(UInt16(0x1fff), at: 0x22)
        page.writeLE(UInt16(0x03ec), at: 0x24)
        page.writeLE(index, at: pageHeaderSize)
        page.writeLE(firstDataPage ?? noPage, at: pageHeaderSize + 4)
        page.writeLE(noPage, at: pageHeaderSize + 8)
        var position = pageHeaderSize + 18
        for _ in 0..<1004 where position + 4 <= pageSize {
            page.replaceSubrange(position..<(position + 4), with: [0xff, 0x1f, 0xf8, 0xff])
            position += 4
        }
        if position + 2 <= pageSize { page.replaceSubrange(position..<(position + 2), with: [0xff, 0x1f]) }
        return page
    }

    /// Splits rows into data pages. A page takes another row while it has room
    /// for the row plus eight bytes.
    private static func paginate(_ rows: [Data], slotted: Bool) -> [Data] {
        var pages: [Data] = []
        var current: [Data] = []
        var heap = 0

        func free(rowCount: Int, heap: Int) -> Int {
            pageSize - pageHeaderSize - heap - max(1, (rowCount + 15) / 16) * rowGroupSize
        }
        for row in rows {
            if !current.isEmpty, free(rowCount: current.count, heap: heap) < row.count + 8 {
                pages.append(dataPage(rows: current, slotted: slotted))
                current = []
                heap = 0
            }
            heap = (heap + 3) / 4 * 4 + row.count
            current.append(row)
        }
        if !current.isEmpty { pages.append(dataPage(rows: current, slotted: slotted)) }
        return pages
    }

    /// One data page, without its page index, type, successor or sequence.
    private static func dataPage(rows: [Data], slotted: Bool) -> Data {
        var page = Data(count: pageSize)
        var heap = 0
        var offsets: [Int] = []
        for (slot, original) in rows.enumerated() {
            var row = original
            if slotted { row.writeLE(UInt16(truncatingIfNeeded: slot * 32), at: 2) }
            heap = (heap + 3) / 4 * 4
            page.replaceSubrange((pageHeaderSize + heap)..<(pageHeaderSize + heap + row.count), with: row)
            offsets.append(heap)
            heap += row.count
        }
        let count = rows.count
        let groups = (count + 15) / 16
        // A page of more than 255 rows records only its last row as touched by
        // the last write; rekordbox crashed on pages that put the count in both words.
        let lastRowMarked = count > 0xff

        let used = (heap + 3) / 4 * 4
        let packed = UInt32(count & 0x1fff) | UInt32(count & 0x7ff) << 13
        page.replaceSubrange(0x18..<0x1b, with: [UInt8(packed & 0xff), UInt8((packed >> 8) & 0xff), UInt8((packed >> 16) & 0xff)])
        page[0x1b] = 0x24
        let free = max(0, pageSize - pageHeaderSize - used - (2 * count + 4 * groups))
        page.writeLE(UInt16(free), at: 0x1c)
        page.writeLE(UInt16(used), at: 0x1e)
        if lastRowMarked {
            page.writeLE(UInt16(1), at: 0x20)
            page.writeLE(UInt16(count - 1), at: 0x22)
        } else {
            page.writeLE(UInt16(count), at: 0x20)
        }

        for group in 0..<groups {
            let base = pageSize - group * rowGroupSize
            let inGroup = min(16, count - group * 16)
            var present: UInt16 = 0
            for slot in 0..<inGroup {
                present |= 1 << UInt16(slot)
                page.writeLE(UInt16(offsets[group * 16 + slot]), at: base - (6 + 2 * slot))
            }
            let second: UInt16 = !lastRowMarked ? present : (group == groups - 1 ? 1 << UInt16(inGroup - 1) : 0)
            page.writeLE(present, at: base - 4)
            page.writeLE(second, at: base - 2)
        }
        return page
    }

    // MARK: - Rows

    private static func trackRow(
        _ track: CDJExportTrack, artistID: UInt32, albumID: UInt32, genreID: UInt32,
        labelID: UInt32, libraryID: UInt32
    ) -> Data {
        let fixed = 0x5E
        var row = Data(count: fixed + 21 * 2)
        // The subtype and both trailer words are part of the record layout: with
        // them zero a CDJ-3000 shows playlists with no tracks in them.
        row.writeLE(UInt16(0x24), at: 0x00)
        row.writeLE(UInt32(track.sampleRate), at: 0x08)
        row.writeLE(UInt32(clamping: track.fileSize), at: 0x10)
        row.writeLE(track.id, at: 0x14)  // master content id
        row.writeLE(libraryID, at: 0x18)  // master db id
        row.writeLE(labelID, at: 0x28)
        row.writeLE(UInt32(track.bitrate), at: 0x30)
        row.writeLE(UInt32(track.trackNumber), at: 0x34)
        row.writeLE(UInt32(max(0, (track.bpm * 100).rounded())), at: 0x38)
        row.writeLE(genreID, at: 0x3c)
        row.writeLE(albumID, at: 0x40)
        row.writeLE(artistID, at: 0x44)
        row.writeLE(track.id, at: 0x48)
        row.writeLE(UInt16(clamping: track.year), at: 0x50)
        row.writeLE(UInt16(16), at: 0x52)
        row.writeLE(UInt16(clamping: track.durationSeconds), at: 0x54)
        row.writeLE(UInt16(0x29), at: 0x56)
        row.writeLE(track.fileType.rawValue, at: 0x5a)
        row.writeLE(UInt16(3), at: 0x5c)

        var strings = [String](repeating: "", count: 21)
        if !track.analyzePath.isEmpty {
            strings[7] = "ON"
            strings[14] = track.analyzePath
        }
        strings[10] = track.dateAdded
        strings[16] = track.comment
        strings[17] = track.title
        strings[19] = track.fileName
        strings[20] = track.stickPath
        for (slot, value) in strings.enumerated() {
            let at = DeviceSQLString.push(value, onto: &row)
            row.writeLE(UInt16(at), at: fixed + slot * 2)
        }
        return row
    }

    private static func artistRow(id: UInt32, name: String) -> Data {
        var row = Data(count: 10)
        row.writeLE(UInt16(0x60), at: 0)
        row.writeLE(id, at: 4)
        row[8] = 0x03
        row[9] = UInt8(DeviceSQLString.push(name, onto: &row))
        return row
    }

    private static func albumRow(id: UInt32, artistID: UInt32, name: String) -> Data {
        var row = Data(count: 0x16)
        row.writeLE(UInt16(0x80), at: 0)
        row.writeLE(artistID, at: 8)
        row.writeLE(id, at: 0x0c)
        row[0x14] = 0x03
        row[0x15] = UInt8(DeviceSQLString.push(name, onto: &row))
        return row
    }

    private static func idNameRow(id: UInt32, name: String) -> Data {
        var row = Data()
        row.appendLE(id)
        row.append(DeviceSQLString.encode(name))
        return row
    }

    /// Four zero bytes, the id as one byte, the id again as two, a pad byte, then the name.
    private static func colorRow(id: UInt16, name: String) -> Data {
        var row = Data(count: 8)
        row[4] = UInt8(id)
        row.writeLE(id, at: 5)
        row.append(DeviceSQLString.encode(name))
        return row
    }

    private static func playlistTreeRow(_ playlist: CDJExportPlaylist) -> Data {
        var row = Data()
        row.appendLE(playlist.parentID)
        row.appendLE(UInt32(0))
        row.appendLE(playlist.sortOrder)
        row.appendLE(playlist.id)
        row.appendLE(UInt32(playlist.isFolder ? 1 : 0))
        row.append(DeviceSQLString.encode(playlist.name))
        return row
    }

    private static func playlistEntryRow(entryIndex: UInt32, trackID: UInt32, playlistID: UInt32) -> Data {
        var row = Data()
        row.appendLE(entryIndex)
        row.appendLE(trackID)
        row.appendLE(playlistID)
        return row
    }

    /// The device library's `property` row: track count, date, version and name.
    private static func propertyRow(contents: Int, createdDate: String, deviceName: String) -> Data {
        var row = Data([0x80, 0x02, 0x00, 0x00])
        row.appendLE(UInt32(contents))
        row.append(contentsOf: [0x00, 0x00, 0x00, 0x00])  // constant, background colour (default), constant
        row.append(DeviceSQLString.encode(createdDate))
        row.append(contentsOf: [0x19, 0x1e])
        row.append(DeviceSQLString.encode("1000"))
        row.append(DeviceSQLString.encode(deviceName))
        row.append(Data(count: 8))
        while row.count % 4 != 0 { row.append(0) }
        return row
    }

    // MARK: - Deduplicated lookup tables

    struct NameTables {
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

/// Pioneer's string encoding: a one-byte header for short ASCII, a
/// length-prefixed form for longer ASCII, and length-prefixed UTF-16LE (with
/// no terminator) for anything else.
enum DeviceSQLString {
    static func encode(_ value: String) -> Data {
        if value.unicodeScalars.allSatisfy({ $0.isASCII }) {
            let bytes = Array(value.utf8)
            if bytes.count < 0x7e {
                return Data([UInt8((bytes.count + 1) * 2 + 1)] + bytes)
            }
            let clipped = bytes.prefix(0xfff0)
            var data = Data([0x40])
            data.appendLE(UInt16(clipped.count + 4))
            data.append(0x00)
            data.append(contentsOf: clipped)
            return data
        }
        let units = Array(value.utf16.prefix(0x7ff0))
        var data = Data([0x90])
        data.appendLE(UInt16(units.count * 2 + 4))
        data.append(0x00)
        for unit in units { data.appendLE(unit) }
        return data
    }

    /// Appends `value` to a row and returns the row offset it starts at. A long
    /// string (ASCII or UTF-16) starts on a four-byte boundary of the row, with
    /// zero bytes filling the gap; a short one follows what is already there.
    static func push(_ value: String, onto row: inout Data) -> Int {
        let encoded = encode(value)
        if let flag = encoded.first, flag == 0x40 || flag == 0x90 {
            while row.count % 4 != 0 { row.append(0) }
        }
        let at = row.count
        row.append(encoded)
        return at
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
