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

/// A read-only view of an `export.pdb`, enough to check one we wrote.
struct RekordboxPDBFile {
    let data: Data

    struct TableEntry {
        var type: UInt32
        var emptyCandidate: Int
        var first: Int
        var last: Int
    }

    init(_ data: Data) throws {
        self.data = data
        guard data.count >= 4096, pageSize == 4096 else {
            throw CDJExportError.verificationFailed("export.pdb has no valid header page.")
        }
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= data.count else { return 0 }
        return data.subdata(in: offset..<(offset + 4)).withUnsafeBytes { $0.loadUnaligned(as: UInt32.self) }.littleEndian
    }

    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= data.count else { return 0 }
        return data.subdata(in: offset..<(offset + 2)).withUnsafeBytes { $0.loadUnaligned(as: UInt16.self) }.littleEndian
    }

    var pageSize: Int { Int(u32(4)) }
    var tableCount: Int { Int(u32(8)) }
    var pageCount: Int { data.count / pageSize }

    var tables: [TableEntry] {
        (0..<tableCount).map { index in
            let base = 0x1c + index * 16
            return TableEntry(
                type: u32(base), emptyCandidate: Int(u32(base + 4)),
                first: Int(u32(base + 8)), last: Int(u32(base + 12)))
        }
    }

    func table(_ type: UInt32) -> TableEntry? { tables.first { $0.type == type } }

    /// Absolute file offsets of the rows in a table, following its page chain.
    /// Throws if the chain is malformed.
    func rowOffsets(inTable type: UInt32) throws -> [Int] {
        guard let table = table(type) else {
            throw CDJExportError.verificationFailed("export.pdb is missing table \(type).")
        }
        let indexBase = table.first * pageSize
        guard indexBase + pageSize <= data.count, data[indexBase + 0x1b] == 0x64 else {
            throw CDJExportError.verificationFailed("Table \(type) does not start with an index page.")
        }
        var rows: [Int] = []
        var page = Int(u32(indexBase + 0x0c))
        var visited = Set<Int>()
        while page != table.emptyCandidate {
            let base = page * pageSize
            guard visited.insert(page).inserted, base + pageSize <= data.count,
                  u32(base + 0x08) == type, data[base + 0x1b] & 0x40 == 0 else {
                throw CDJExportError.verificationFailed("Table \(type) has a broken page chain.")
            }
            let packed = UInt32(data[base + 0x18]) | UInt32(data[base + 0x19]) << 8 | UInt32(data[base + 0x1a]) << 16
            let count = Int(packed & 0x1fff)
            for row in 0..<count {
                let flagsAt = base + pageSize - (row / 16) * 0x24 - 4
                guard flagsAt - 2 * (row % 16 + 1) > base else {
                    throw CDJExportError.verificationFailed("Table \(type) has a row index off its page.")
                }
                let present = u16(flagsAt) & (1 << UInt16(row % 16)) != 0
                if present { rows.append(base + 0x28 + Int(u16(flagsAt - 2 * (row % 16 + 1)))) }
            }
            if page == table.last { break }
            page = Int(u32(base + 0x0c))
        }
        return rows
    }

    /// Reads a short-ASCII, long-ASCII or UTF-16LE string.
    func string(at offset: Int) -> String {
        guard offset >= 0, offset < data.count else { return "" }
        let header = data[offset]
        if header & 1 == 1 {
            let length = Int(header >> 1) - 1
            guard length >= 0, offset + 1 + length <= data.count else { return "" }
            return String(decoding: data.subdata(in: (offset + 1)..<(offset + 1 + length)), as: UTF8.self)
        }
        let total = Int(u16(offset + 1))
        guard total >= 4, offset + total <= data.count else { return "" }
        let body = data.subdata(in: (offset + 4)..<(offset + total))
        if header == 0x40 { return String(decoding: body, as: UTF8.self) }
        return String(data: body, encoding: .utf16LittleEndian) ?? ""
    }
}

/// Checks a staged export before it is published: the databases must be
/// structurally sound, agree with the plan, and name only files that exist.
enum RekordboxExportVerifier {
    /// - Parameter fileExists: whether a leading-slash stick path will exist once published.
    static func verify(
        database: Data, plan: CDJExportPlan, analysis: (String) -> Data?, fileExists: (String) -> Bool
    ) throws {
        let file = try RekordboxPDBFile(database)
        guard file.tableCount == RekordboxPDBWriter.tableCount else {
            throw CDJExportError.verificationFailed("export.pdb has \(file.tableCount) tables, expected 20.")
        }
        for table in file.tables {
            _ = try file.rowOffsets(inTable: table.type)
        }

        let trackRows = try file.rowOffsets(inTable: RekordboxPDBWriter.TableType.tracks)
        let trackIDs = trackRows.map { file.u32($0 + 0x48) }
        guard trackIDs.count == plan.items.count, Set(trackIDs).count == trackIDs.count else {
            throw CDJExportError.verificationFailed(
                "export.pdb lists \(trackIDs.count) tracks but \(plan.items.count) were planned.")
        }
        for row in trackRows {
            guard file.u16(row) == 0x24, file.u16(row + 0x56) == 0x29, file.u16(row + 0x5c) == 3 else {
                throw CDJExportError.verificationFailed("A track row is missing its required header words.")
            }
            let path = file.string(at: row + Int(file.u16(row + 0x5E + 20 * 2)))
            guard fileExists(path) else {
                throw CDJExportError.verificationFailed("export.pdb names \(path), which isn't on the stick.")
            }
        }

        let playlistIDs = Set(try file.rowOffsets(inTable: RekordboxPDBWriter.TableType.playlistTree).map { file.u32($0 + 12) })
        let known = Set(trackIDs)
        for row in try file.rowOffsets(inTable: RekordboxPDBWriter.TableType.playlistTree) {
            let parent = file.u32(row)
            guard parent == 0 || playlistIDs.contains(parent) else {
                throw CDJExportError.verificationFailed("A playlist's parent folder is missing.")
            }
        }
        for row in try file.rowOffsets(inTable: RekordboxPDBWriter.TableType.playlistEntries) {
            guard known.contains(file.u32(row + 4)), playlistIDs.contains(file.u32(row + 8)) else {
                throw CDJExportError.verificationFailed("A playlist entry points at a track or playlist that doesn't exist.")
            }
        }

        for item in plan.items {
            guard let dat = analysis(item.export.analyzePath) else {
                throw CDJExportError.verificationFailed("\(item.export.analyzePath) is missing.")
            }
            try verifyAnalysis(dat, audioPath: item.export.stickPath)
        }
    }

    /// An ANLZ file is a `PMAI` container whose sections run exactly to its end
    /// and whose `PPTH` names the audio file it belongs to.
    static func verifyAnalysis(_ data: Data, audioPath: String) throws {
        func u32(_ at: Int) -> Int {
            guard at + 4 <= data.count else { return 0 }
            return Int(data.subdata(in: at..<(at + 4)).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
        }
        guard data.count >= 28, String(bytes: data.prefix(4), encoding: .ascii) == "PMAI", u32(8) == data.count else {
            throw CDJExportError.verificationFailed("An analysis file for \(audioPath) is malformed.")
        }
        var offset = u32(4)
        var path: String?
        while offset < data.count {
            let length = u32(offset + 8)
            guard length >= 12, offset + length <= data.count else {
                throw CDJExportError.verificationFailed("An analysis file for \(audioPath) has a broken section.")
            }
            if String(bytes: data.subdata(in: offset..<(offset + 4)), encoding: .ascii) == "PPTH" {
                let headerLength = u32(offset + 4)
                let body = data.subdata(in: (offset + headerLength)..<(offset + length))
                path = String(data: body, encoding: .utf16BigEndian)?.trimmingCharacters(in: CharacterSet(["\0"]))
            }
            offset += length
        }
        guard path == audioPath else {
            throw CDJExportError.verificationFailed("An analysis file names \(path ?? "no file") instead of \(audioPath).")
        }
    }

    /// Reads `exportLibrary.db` back and checks it agrees with the plan and with `export.pdb`:
    /// it opens under the key, has every table, and lists the same tracks with intact playlists.
    static func verifyOneLibrary(at url: URL, plan: CDJExportPlan, tracks: [CDJExportTrack]) throws {
        func fail(_ detail: String) -> CDJExportError { .verificationFailed("exportLibrary.db: \(detail)") }
        let database: CDJSQLiteDatabase
        do {
            database = try CDJSQLiteDatabase(url: url, passphrase: OneLibraryKey.passphrase(), readOnly: true)
        } catch {
            throw fail("it can't be opened.")
        }
        do {
            let tables = try database.rows("SELECT name FROM sqlite_master WHERE type = 'table'", columns: 1)
            guard tables.count >= OneLibraryWriter.schema.count else { throw fail("it is missing tables.") }

            let content = try database.rows("SELECT content_id, path, analysisDataFilePath FROM content", columns: 3)
            let expected = Dictionary(uniqueKeysWithValues: tracks.map { ($0.id, $0) })
            guard content.count == tracks.count else {
                throw fail("it lists \(content.count) tracks but \(tracks.count) were exported.")
            }
            for row in content {
                guard let id = row[0].intValue, let track = expected[UInt32(truncatingIfNeeded: id)],
                      row[1].textValue == track.stickPath, row[2].textValue == track.analyzePath else {
                    throw fail("a track disagrees with export.pdb.")
                }
            }
            let playlists = try database.rows("SELECT playlist_id, playlist_id_parent FROM playlist", columns: 2)
            let playlistIDs = Set(playlists.compactMap { $0[0].intValue })
            guard playlistIDs.count == plan.playlists.count,
                  playlists.allSatisfy({ ($0[1].intValue ?? 0) == 0 || playlistIDs.contains($0[1].intValue ?? 0) }) else {
                throw fail("its playlists don't match the plan.")
            }
            let orphans = try database.rows(
                """
                SELECT COUNT(*) FROM playlist_content
                WHERE content_id NOT IN (SELECT content_id FROM content)
                   OR playlist_id NOT IN (SELECT playlist_id FROM playlist)
                """, columns: 1)
            guard orphans.first?.first?.intValue == 0 else { throw fail("a playlist entry points at a missing track.") }
            let counted = try database.rows("SELECT numberOfContents FROM property", columns: 1).first?.first?.intValue
            guard counted == Int64(tracks.count) else { throw fail("its track count is wrong.") }
        } catch let error as CDJExportError {
            throw error
        } catch {
            throw fail("it couldn't be read back.")
        }
    }
}
