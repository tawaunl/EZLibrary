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
import Testing
@testable import EZLibraryCore

/// Minimal reader for the pages `RekordboxPDBWriter` produces, so the tests
/// check the file the way a player would walk it rather than echoing the writer.
private struct PDBReader {
    let data: Data

    func u32(_ offset: Int) -> UInt32 {
        data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }
    func u16(_ offset: Int) -> UInt16 {
        data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }

    var pageSize: Int { Int(u32(4)) }
    var tableCount: Int { Int(u32(8)) }

    func table(_ type: UInt32) -> (first: Int, last: Int, empty: Int)? {
        for index in 0..<tableCount where u32(0x1c + index * 16) == type {
            let base = 0x1c + index * 16
            return (Int(u32(base + 8)), Int(u32(base + 12)), Int(u32(base + 4)))
        }
        return nil
    }

    /// Row byte offsets (absolute within the file) for every row in a table, following the page chain.
    func rows(inTable type: UInt32) -> [Int] {
        guard let table = table(type) else { return [] }
        var result: [Int] = []
        var page = Int(u32(table.first * pageSize + 0x0c))
        while page != table.empty {
            let base = page * pageSize
            let count = Int(data[base + 0x18])
            for row in 0..<count {
                let group = row / 16
                let flagsPos = base + pageSize - group * 0x24 - 4
                let offset = Int(u16(flagsPos - 2 * (row % 16 + 1)))
                result.append(base + 0x28 + offset)
            }
            page = Int(u32(base + 0x0c))
        }
        return result
    }

    func string(at offset: Int) -> String {
        let header = data[offset]
        if header & 1 == 1 {
            let length = Int(header >> 1) - 1
            return String(decoding: data.subdata(in: (offset + 1)..<(offset + 1 + length)), as: UTF8.self)
        }
        let total = Int(u16(offset + 1))
        let units = data.subdata(in: (offset + 4)..<(offset + total))
        return String(data: units, encoding: .utf16LittleEndian) ?? ""
    }
}

private func makeTrack(_ id: UInt32, title: String, artist: String = "A", album: String = "B") -> CDJExportTrack {
    CDJExportTrack(
        id: id, title: title, artist: artist, album: album, genre: "House", bpm: 124.5,
        stickPath: "/Contents/\(artist)/\(album)/\(title).mp3")
}

@Test func pdbHeaderDescribesPagesAndTables() {
    let data = RekordboxPDBWriter.build(tracks: [makeTrack(1, title: "One")], playlists: [])
    let reader = PDBReader(data: data)
    #expect(reader.pageSize == 4096)
    #expect(reader.tableCount == 20)
    #expect(data.count % 4096 == 0)
    #expect(Int(reader.u32(12)) * 4096 == data.count)
}

@Test func pdbTrackRowsRoundTrip() throws {
    let tracks = [makeTrack(1, title: "One"), makeTrack(2, title: "Ünïcode ☃")]
    let reader = PDBReader(data: RekordboxPDBWriter.build(tracks: tracks, playlists: []))
    let rows = reader.rows(inTable: 0)
    #expect(rows.count == 2)
    #expect(reader.u32(rows[0] + 0x48) == 1)
    #expect(reader.u32(rows[0] + 0x38) == 12_450)
    // Slot 17 is the title, slot 20 the file path.
    let titleOffset = Int(reader.u16(rows[1] + 0x5E + 17 * 2))
    #expect(reader.string(at: rows[1] + titleOffset) == "Ünïcode ☃")
    let pathOffset = Int(reader.u16(rows[0] + 0x5E + 20 * 2))
    #expect(reader.string(at: rows[0] + pathOffset) == "/Contents/A/B/One.mp3")
}

@Test func pdbSharesArtistAndAlbumRows() {
    let tracks = (1...5).map { makeTrack(UInt32($0), title: "T\($0)") }
    let reader = PDBReader(data: RekordboxPDBWriter.build(tracks: tracks, playlists: []))
    #expect(reader.rows(inTable: 2).count == 1)  // artists
    #expect(reader.rows(inTable: 3).count == 1)  // albums
    #expect(reader.rows(inTable: 1).count == 1)  // genres
    let rows = reader.rows(inTable: 0)
    #expect(Set(rows.map { reader.u32($0 + 0x44) }) == [1])
}

@Test func pdbSpillsManyRowsAcrossPages() {
    let tracks = (1...300).map { makeTrack(UInt32($0), title: "Track number \($0)") }
    let reader = PDBReader(data: RekordboxPDBWriter.build(tracks: tracks, playlists: []))
    let rows = reader.rows(inTable: 0)
    #expect(rows.count == 300)
    #expect(Set(rows.map { reader.u32($0 + 0x48) }).count == 300)
}

@Test func pdbWritesPlaylistTreeAndEntriesInOrder() {
    let playlists = [
        CDJExportPlaylist(id: 1, name: "Folder", isFolder: true),
        CDJExportPlaylist(id: 2, parentID: 1, name: "Set", trackIDs: [2, 1])
    ]
    let reader = PDBReader(data: RekordboxPDBWriter.build(
        tracks: [makeTrack(1, title: "a"), makeTrack(2, title: "b")], playlists: playlists))
    let tree = reader.rows(inTable: 7)
    #expect(tree.count == 2)
    #expect(reader.u32(tree[1]) == 1)  // parent id
    #expect(reader.string(at: tree[1] + 20) == "Set")
    let entries = reader.rows(inTable: 8)
    #expect(entries.map { reader.u32($0 + 4) } == [2, 1])
    #expect(entries.allSatisfy { reader.u32($0 + 8) == 2 })
}

@Test func emptyTablesStillHaveAnIndexPage() {
    let reader = PDBReader(data: RekordboxPDBWriter.build(tracks: [], playlists: []))
    for type in UInt32(0)..<20 {
        let table = reader.table(type)
        #expect(table != nil)
        #expect(reader.rows(inTable: type).isEmpty)
    }
}

@Test func deviceSQLStringForms() {
    #expect(DeviceSQLString.encode("") == Data([0x03]))
    #expect(DeviceSQLString.encode("ab") == Data([0x07, 0x61, 0x62]))
    #expect(DeviceSQLString.encode("é").first == 0x90)
}

@Test func stickPathsAreFATSafeAndUnique() {
    var used = Set<String>()
    let url = URL(fileURLWithPath: "/m/Song?.mp3")
    let track = Track(seratoStoredPath: "m/Song?.mp3", fileURL: url, artist: "AC/DC", album: "")
    let first = CDJSeratoExport.uniqueStickPath(for: track, used: &used)
    let second = CDJSeratoExport.uniqueStickPath(for: track, used: &used)
    #expect(first == "/Contents/AC_DC/Unknown Album/Song_.mp3")
    #expect(second == "/Contents/AC_DC/Unknown Album/Song_ (2).mp3")
}

@Test func planMapsNestedCratesToFoldersAndReportsProblems() throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("cdjplan-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: dir) }

    func makeFile(_ name: String) throws -> Track {
        let url = dir.appendingPathComponent(name)
        try Data("x".utf8).write(to: url)
        return Track(seratoStoredPath: "p/\(name)", fileURL: url, title: name)
    }
    let good = try makeFile("good.mp3")
    let weird = try makeFile("weird.ogg")
    let gone = Track(seratoStoredPath: "p/gone.mp3", fileURL: dir.appendingPathComponent("gone.mp3"))

    let crate = Crate(
        pathComponents: ["ALL GENRES", "Disco"],
        trackPaths: [good.seratoStoredPath, weird.seratoStoredPath, gone.seratoStoredPath, good.seratoStoredPath])
    let plan = CDJSeratoExport.plan(crates: [crate], library: [good, weird, gone])

    #expect(plan.items.count == 1)
    #expect(plan.missing.map(\.seratoStoredPath) == ["p/gone.mp3"])
    #expect(plan.unsupported.map(\.seratoStoredPath) == ["p/weird.ogg"])
    #expect(plan.playlists.map(\.name) == ["ALL GENRES", "Disco"])
    #expect(plan.playlists[0].isFolder)
    #expect(plan.playlists[1].parentID == plan.playlists[0].id)
    #expect(plan.playlists[1].trackIDs == [1, 1])
}

@Test func exportRefusesPathsThatAreNotVolumes() async {
    let plan = CDJExportPlan(
        items: [.init(source: URL(fileURLWithPath: "/x.mp3"), export: makeTrack(1, title: "x"))],
        playlists: [], missing: [], unsupported: [])
    await #expect(throws: CDJExportError.self) {
        try await CDJSeratoExport.export(plan, to: FileManager.default.temporaryDirectory)
    }
}
