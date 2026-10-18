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

/// The per-stick browse settings in `exportLibrary.db`: which categories and
/// sort columns a player offers, and the names of the eight cue colours. A stick
/// that already has them keeps them across exports.
struct OneLibrarySettings: Equatable {
    struct Category: Equatable { var id: Int64; var menuItem: Int64; var sequence: Int64; var visible: Bool }
    struct Sort: Equatable {
        var id: Int64; var menuItem: Int64; var sequence: Int64; var visible: Bool; var isSubColumn: Bool
    }
    struct Color: Equatable { var id: Int64; var name: String }

    var categories: [Category]
    var sorts: [Sort]
    var colors: [Color]
    var backgroundColorType: Int64

    /// rekordbox's defaults for a blank stick.
    static let defaults = OneLibrarySettings(
        categories: OneLibraryWriter.categories.map {
            Category(id: $0.0, menuItem: $0.1, sequence: $0.2, visible: $0.3 != 0)
        },
        sorts: OneLibraryWriter.sorts.map {
            Sort(id: $0.0, menuItem: $0.1, sequence: $0.2, visible: $0.3 != 0, isSubColumn: $0.4 != 0)
        },
        colors: OneLibraryWriter.colorNames.enumerated().map { Color(id: Int64($0.offset + 1), name: $0.element) },
        backgroundColorType: 0)

    /// Reads the settings from an existing `exportLibrary.db`, or nil if it can't be read.
    static func read(from url: URL) -> OneLibrarySettings? {
        guard let passphrase = try? OneLibraryKey.passphrase(),
              let database = try? CDJSQLiteDatabase(url: url, passphrase: passphrase, readOnly: true) else { return nil }
        do {
            let categories = try database.rows(
                "SELECT category_id, menuItem_id, sequenceNo, isVisible FROM category", columns: 4
            ).compactMap { row -> Category? in
                guard let id = row[0].intValue, let item = row[1].intValue else { return nil }
                return Category(id: id, menuItem: item, sequence: row[2].intValue ?? 0, visible: (row[3].intValue ?? 0) != 0)
            }
            let sorts = try database.rows(
                "SELECT sort_id, menuItem_id, sequenceNo, isVisible, isSelectedAsSubColumn FROM sort", columns: 5
            ).compactMap { row -> Sort? in
                guard let id = row[0].intValue, let item = row[1].intValue else { return nil }
                return Sort(
                    id: id, menuItem: item, sequence: row[2].intValue ?? 0, visible: (row[3].intValue ?? 0) != 0,
                    isSubColumn: (row[4].intValue ?? 0) != 0)
            }
            let colors = try database.rows("SELECT color_id, name FROM color", columns: 2).compactMap { row -> Color? in
                guard let id = row[0].intValue, let name = row[1].textValue else { return nil }
                return Color(id: id, name: name)
            }
            let background = try database.rows("SELECT backGroundColorType FROM property", columns: 1).first?.first?.intValue
            guard !categories.isEmpty, !sorts.isEmpty else { return nil }
            return OneLibrarySettings(
                categories: categories, sorts: sorts, colors: colors, backgroundColorType: background ?? 0)
        } catch {
            return nil
        }
    }
}

/// Writes `exportLibrary.db`, the SQLCipher database ("OneLibrary") that
/// rekordbox's device panel and the newest players read in place of, or beside,
/// `export.pdb`. The schema and browse rows are rekordbox 7's, as documented in
/// the rbxport project's USB export reference. Ids match `export.pdb`'s.
enum OneLibraryWriter {
    static let dbVersion = "1000"

    static func write(
        to url: URL,
        tracks: [CDJExportTrack],
        playlists: [CDJExportPlaylist],
        analyses: [UInt32: SeratoTrackAnalysis],
        deviceName: String,
        createdDate: String,
        libraryID: UInt32,
        settings: OneLibrarySettings = .defaults
    ) throws {
        try? FileManager.default.removeItem(at: url)
        let database = try CDJSQLiteDatabase(url: url, passphrase: OneLibraryKey.passphrase())
        // No -wal / -shm files: a player that doesn't replay a journal would read an empty database.
        try database.execute("PRAGMA journal_mode = DELETE")
        try database.execute("PRAGMA synchronous = EXTRA")
        try database.execute("BEGIN IMMEDIATE")
        do {
            for statement in schema { try database.execute(statement) }
            try writeBrowseTables(database, settings: settings)

            // The same interning order as export.pdb, so both databases number things alike.
            var names = RekordboxPDBWriter.NameTables()
            let ordered = tracks.sorted { $0.id < $1.id }
            for track in ordered {
                let artistID = names.artistID(track.artist)
                let albumID = names.albumID(track.album, artistID: artistID)
                let genreID = names.genreID(track.genre)
                let labelID = names.labelID(track.label)
                try insert(track, artist: artistID, album: albumID, genre: genreID, label: labelID,
                           libraryID: libraryID, into: database)
                try insertCues(for: track, analysis: analyses[track.id], into: database)
            }
            for artist in names.artists {
                try database.run("INSERT INTO artist (artist_id, name, nameForSearch) VALUES (?, ?, ?)",
                                 [.int(artist.id), .text(artist.name), .text(artist.name)])
            }
            for album in names.albums {
                try database.run("INSERT INTO album (album_id, name, artist_id) VALUES (?, ?, ?)",
                                 [.int(album.id), .text(album.name), .int(album.artistID)])
            }
            for genre in names.genres {
                try database.run("INSERT INTO genre (genre_id, name) VALUES (?, ?)", [.int(genre.id), .text(genre.name)])
            }
            for label in names.labels {
                try database.run("INSERT INTO label (label_id, name) VALUES (?, ?)", [.int(label.id), .text(label.name)])
            }
            try insertPlaylists(playlists, into: database)
            try database.run(
                """
                INSERT INTO property (deviceName, dbVersion, numberOfContents, createdDate, backGroundColorType, myTagMasterDBID)
                VALUES (?, ?, ?, ?, ?, ?)
                """,
                [.text(deviceName), .text(dbVersion), .int(tracks.count), .text(createdDate),
                 .int(settings.backgroundColorType), .int(libraryID)])
            try database.execute("COMMIT")
        } catch {
            try? database.execute("ROLLBACK")
            throw error
        }
    }

    // MARK: - Rows

    private static func writeBrowseTables(_ database: CDJSQLiteDatabase, settings: OneLibrarySettings) throws {
        for item in menuItems {
            try database.run(
                "INSERT INTO menuItem (menuItem_id, kind, name) VALUES (?, ?, ?)",
                [.int(item.0), .int(item.1), .text("\u{FFFA}\(item.2)\u{FFFB}")])
        }
        // A settings row naming a menu item we don't know is dropped rather than left dangling.
        let known = Set(menuItems.map(\.0))
        for category in settings.categories where known.contains(category.menuItem) {
            try database.run(
                "INSERT INTO category (category_id, menuItem_id, sequenceNo, isVisible) VALUES (?, ?, ?, ?)",
                [.int(category.id), .int(category.menuItem), .int(category.sequence), .int(category.visible ? 1 : 0)])
        }
        for sort in settings.sorts where known.contains(sort.menuItem) {
            try database.run(
                "INSERT INTO sort (sort_id, menuItem_id, sequenceNo, isVisible, isSelectedAsSubColumn) VALUES (?, ?, ?, ?, ?)",
                [.int(sort.id), .int(sort.menuItem), .int(sort.sequence), .int(sort.visible ? 1 : 0),
                 .int(sort.isSubColumn ? 1 : 0)])
        }
        // Always eight colours in rekordbox's order; a stick's own names replace ours.
        for (index, defaultName) in colorNames.enumerated() {
            let id = Int64(index + 1)
            let name = settings.colors.first { $0.id == id }?.name ?? defaultName
            try database.run("INSERT INTO color (color_id, name) VALUES (?, ?)", [.int(id), .text(name)])
        }
    }

    private static func insert(
        _ track: CDJExportTrack, artist: UInt32, album: UInt32, genre: UInt32, label: UInt32,
        libraryID: UInt32, into database: CDJSQLiteDatabase
    ) throws {
        func lookup(_ id: UInt32) -> CDJSQLValue { id == 0 ? .int(0) : .int(id) }
        try database.run(
            """
            INSERT INTO content
                (content_id, title, titleForSearch, bpmx100, length, trackNo, discNo, artist_id_artist, album_id,
                 genre_id, label_id, key_id, color_id, djComment, rating, releaseYear, releaseDate, dateCreated,
                 dateAdded, path, fileName, fileSize, fileType, bitrate, bitDepth, samplingRate, isrc, djPlayCount,
                 isHotCueAutoLoadOn, masterDbId, masterContentId, analysisDataFilePath, analysedBits, hasModified)
            VALUES (?, ?, ?, ?, ?, ?, 0, ?, ?, ?, ?, 0, 0, ?, 0, ?, '', ?, ?, ?, ?, ?, ?, ?, 16, ?, '', 0, ?, ?, ?, ?, ?, 0)
            """,
            [
                .int(track.id), .text(track.title), .text(track.title),
                .int(Int((track.bpm * 100).rounded())), .int(track.durationSeconds), .int(track.trackNumber),
                lookup(artist), lookup(album), lookup(genre), lookup(label),
                .text(track.comment), .int(track.year), .text(track.dateAdded), .text(track.dateAdded),
                .text(track.stickPath), .text(track.fileName), .int(track.fileSize),
                .int(Int(track.fileType.rawValue)), .int(track.bitrate), .int(track.sampleRate),
                // Hot-cue auto-load must agree with the "ON" flag in export.pdb's track row.
                .int(track.analyzePath.isEmpty ? 0 : 1),
                .int(libraryID), .int(track.id), .text(track.analyzePath), .int(41)
            ])
    }

    /// Cue rows: kind 0 is a memory cue, 1-3 are hot cues A-C and 5-17 are D-P (4 is reserved).
    private static func insertCues(for track: CDJExportTrack, analysis: SeratoTrackAnalysis?, into database: CDJSQLiteDatabase) throws {
        guard let analysis else { return }
        func row(kind: Int, colour: Int, name: String, startMs: Int, endMs: Int?) throws {
            let framesPerSecond = 150
            try database.run(
                """
                INSERT INTO cue (content_id, kind, colorTableIndex, cueComment, isActiveLoop, beatLoopNumerator,
                                 beatLoopDenominator, inUsec, outUsec, in150FramePerSec, out150FramePerSec)
                VALUES (?, ?, ?, ?, 0, 0, 0, ?, ?, ?, ?)
                """,
                [.int(track.id), .int(kind), .int(colour), .text(name),
                 .int(startMs * 1000), .int(endMs.map { $0 * 1000 } ?? -1),
                 .int(startMs * framesPerSecond / 1000), .int(endMs.map { $0 * framesPerSecond / 1000 } ?? -1)])
        }
        for cue in analysis.cues where cue.index < RekordboxAnalysisWriter.hotCueSlots {
            let slot = cue.index + 1
            let kind = slot <= 3 ? slot : slot + 1
            try row(kind: kind, colour: Int(RekordboxCuePalette.nearest(to: cue.color).code), name: cue.name,
                    startMs: cue.positionMs, endMs: nil)
        }
        // Serato's saved loops become memory loops, as in the analysis files.
        for loop in analysis.loops {
            try row(kind: 0, colour: Int(RekordboxCuePalette.nearest(to: loop.color).code), name: loop.name,
                    startMs: loop.startMs, endMs: loop.endMs)
        }
    }

    private static func insertPlaylists(_ playlists: [CDJExportPlaylist], into database: CDJSQLiteDatabase) throws {
        for playlist in playlists.sorted(by: { $0.id < $1.id }) {
            try database.run(
                """
                INSERT INTO playlist (playlist_id, sequenceNo, name, image_id, attribute, playlist_id_parent)
                VALUES (?, ?, ?, NULL, ?, ?)
                """,
                [.int(playlist.id), .int(playlist.sortOrder), .text(playlist.name),
                 .int(playlist.isFolder ? 1 : 0), .int(playlist.parentID)])
            guard !playlist.isFolder else { continue }
            for (index, trackID) in playlist.trackIDs.enumerated() {
                try database.run(
                    "INSERT INTO playlist_content (playlist_id, content_id, sequenceNo) VALUES (?, ?, ?)",
                    [.int(playlist.id), .int(trackID), .int(index + 1)])
            }
        }
    }

    // MARK: - Reference data

    static let colorNames = ["Pink", "Red", "Orange", "Yellow", "Green", "Aqua", "Blue", "Purple"]

    /// `(menuItem_id, kind, name)`. Names are wrapped in U+FFFA/U+FFFB when written, which is how
    /// rekordbox flags a string for display-time translation.
    static let menuItems: [(Int64, Int64, String)] = [
        (1, 128, "GENRE"), (2, 129, "ARTIST"), (3, 130, "ALBUM"), (4, 131, "TRACK"), (5, 133, "BPM"),
        (6, 134, "RATING"), (7, 135, "YEAR"), (8, 136, "REMIXER"), (9, 137, "LABEL"), (10, 138, "ORIGINAL ARTIST"),
        (11, 139, "KEY"), (12, 141, "CUE"), (13, 142, "COLOR"), (14, 146, "TIME"), (15, 147, "BITRATE"),
        (16, 148, "FILE NAME"), (17, 132, "PLAYLIST"), (18, 152, "HOT CUE BANK"), (19, 149, "HISTORY"),
        (20, 145, "SEARCH"), (21, 150, "COMMENTS"), (22, 140, "DATE ADDED"), (23, 151, "DJ PLAY COUNT"),
        (24, 144, "FOLDER"), (25, 161, "DEFAULT"), (26, 162, "ALPHABET"), (27, 170, "MATCHING")
    ]

    /// `(category_id, menuItem_id, sequenceNo, isVisible)`.
    static let categories: [(Int64, Int64, Int64, Int64)] = [
        (1, 1, 0, 0), (2, 2, 1, 1), (3, 3, 2, 1), (4, 4, 3, 1), (5, 17, 5, 1), (6, 5, 0, 0), (7, 6, 0, 0),
        (8, 7, 0, 0), (9, 8, 0, 0), (10, 9, 0, 0), (11, 10, 0, 0), (12, 11, 4, 1), (15, 13, 0, 0), (17, 24, 9, 1),
        (18, 20, 7, 1), (19, 14, 0, 0), (20, 15, 0, 0), (21, 16, 0, 0), (22, 19, 6, 1), (23, 18, 0, 0),
        (26, 27, 8, 1), (27, 22, 10, 1)
    ]

    /// `(sort_id, menuItem_id, sequenceNo, isVisible, isSelectedAsSubColumn)`.
    static let sorts: [(Int64, Int64, Int64, Int64, Int64)] = [
        (0, 25, 1, 1, 0), (1, 26, 2, 1, 0), (2, 2, 3, 1, 0), (3, 3, 4, 1, 0), (4, 5, 5, 1, 0), (5, 6, 6, 1, 0),
        (6, 1, 0, 0, 0), (7, 21, 0, 0, 1), (8, 14, 0, 0, 0), (9, 8, 0, 0, 0), (10, 9, 0, 0, 0), (11, 10, 0, 0, 0),
        (12, 11, 7, 1, 0), (13, 15, 0, 0, 0), (15, 13, 0, 0, 0), (16, 23, 0, 0, 0), (17, 22, 0, 0, 0)
    ]

    /// Every table is created, empty or not; the spellings (`isComplation`, `OutFileOffsetInBlock`) are rekordbox's.
    static let schema = [
        "CREATE TABLE album(album_id integer primary key, name varchar, artist_id integer, image_id integer, isComplation integer, nameForSearch varchar)",
        "CREATE TABLE artist(artist_id integer primary key, name varchar, nameForSearch varchar)",
        "CREATE TABLE category(category_id integer primary key, menuItem_id integer, sequenceNo integer, isVisible integer)",
        "CREATE TABLE color(color_id integer primary key, name varchar)",
        """
        CREATE TABLE content(\
        content_id integer primary key, title varchar, titleForSearch varchar, subtitle varchar, bpmx100 integer, length integer, \
        trackNo integer, discNo integer, artist_id_artist integer, artist_id_remixer integer, artist_id_originalArtist integer, artist_id_composer integer, \
        artist_id_lyricist integer, album_id integer, genre_id integer, label_id integer, key_id integer, color_id integer, \
        image_id integer, djComment varchar, rating integer, releaseYear integer, releaseDate varchar, dateCreated varchar, \
        dateAdded varchar, path varchar, fileName varchar, fileSize integer, fileType integer, bitrate integer, \
        bitDepth integer, samplingRate integer, isrc varchar, djPlayCount integer, isHotCueAutoLoadOn integer, isKuvoDeliverStatusOn integer, \
        kuvoDeliveryComment varchar, masterDbId integer, masterContentId integer, analysisDataFilePath varchar, analysedBits integer, contentLink integer, \
        hasModified integer, cueUpdateCount integer, analysisDataUpdateCount integer, informationUpdateCount integer)
        """,
        """
        CREATE TABLE cue(\
        cue_id integer primary key, content_id integer, kind integer, colorTableIndex integer, cueComment varchar, isActiveLoop integer, \
        beatLoopNumerator integer, beatLoopDenominator integer, inUsec integer, outUsec integer, in150FramePerSec integer, out150FramePerSec integer, \
        inMpegFrameNumber integer, outMpegFrameNumber integer, inMpegAbs integer, outMpegAbs integer, inDecodingStartFramePosition integer, outDecodingStartFramePosition integer, \
        inFileOffsetInBlock integer, OutFileOffsetInBlock integer, inNumberOfSampleInBlock integer, outNumberOfSampleInBlock integer)
        """,
        "CREATE TABLE genre(genre_id integer primary key, name varchar)",
        "CREATE TABLE history(history_id integer primary key, sequenceNo integer, name varchar, attribute integer, history_id_parent integer)",
        "CREATE TABLE history_content(history_id integer, content_id integer, sequenceNo integer)",
        "CREATE TABLE hotCueBankList(hotCueBankList_id integer primary key, sequenceNo integer, name varchar, image_id integer, attribute integer, hotCueBankList_id_parent integer)",
        "CREATE TABLE hotCueBankList_cue(hotCueBankList_id integer, cue_id integer, sequenceNo integer)",
        "CREATE TABLE image(image_id integer primary key, path varchar)",
        "CREATE TABLE key(key_id integer primary key, name varchar)",
        "CREATE TABLE label(label_id integer primary key, name varchar)",
        "CREATE TABLE menuItem(menuItem_id integer primary key, kind integer, name varchar)",
        "CREATE TABLE myTag(myTag_id integer primary key, sequenceNo integer, name varchar, attribute integer, myTag_id_parent integer)",
        "CREATE TABLE myTag_content(myTag_id integer, content_id integer)",
        "CREATE TABLE playlist(playlist_id integer primary key, sequenceNo integer, name varchar, image_id integer, attribute integer, playlist_id_parent integer)",
        "CREATE TABLE playlist_content(playlist_id integer, content_id integer, sequenceNo integer)",
        "CREATE TABLE property(deviceName varchar, dbVersion varchar, numberOfContents integer, createdDate varchar, backGroundColorType integer, myTagMasterDBID integer)",
        "CREATE TABLE recommendedLike(content_id_1 integer, content_id_2 integer, rating integer, createdDate integer)",
        "CREATE TABLE sort(sort_id integer primary key, menuItem_id integer, sequenceNo integer, isVisible integer, isSelectedAsSubColumn integer)"
    ]
}
