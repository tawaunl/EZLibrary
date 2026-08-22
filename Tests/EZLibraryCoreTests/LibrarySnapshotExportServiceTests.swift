// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Testing
import Foundation
@testable import EZLibraryCore

private struct ExportScratch {
    let root: URL
    let libraryDirectory: URL
    let destination: URL
}

private func makeExportScratch() throws -> ExportScratch {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ezlibrary-export-\(UUID().uuidString)", isDirectory: true)
    let libraryDirectory = root.appendingPathComponent("_Serato_", isDirectory: true)
    try FileManager.default.createDirectory(
        at: SeratoLibraryLocator.subcratesDirectory(in: libraryDirectory),
        withIntermediateDirectories: true
    )
    try Data("db".utf8).write(to: SeratoLibraryLocator.databaseFile(in: libraryDirectory))
    return ExportScratch(
        root: root,
        libraryDirectory: libraryDirectory,
        destination: root.appendingPathComponent("EZLibrary", isDirectory: true)
    )
}

private func sampleTracks(_ count: Int = 2) -> [Track] {
    (0..<count).map { index in
        Track(
            seratoStoredPath: "Music/Track \(index).mp3",
            fileURL: URL(fileURLWithPath: "/Music/Track \(index).mp3"),
            title: "Track \(index)",
            artist: "Nova"
        )
    }
}

@Test func exportWritesASnapshotNamedForTheLibraryState() throws {
    let scratch = try makeExportScratch()
    defer { try? FileManager.default.removeItem(at: scratch.root) }

    let result = try LibrarySnapshotExportService.export(
        tracks: sampleTracks(),
        crates: [Crate(pathComponents: ["Warmup"], trackPaths: ["Music/Track 0.mp3"])],
        libraryDirectory: scratch.libraryDirectory,
        to: scratch.destination
    )

    #expect(result.trackCount == 2)
    #expect(result.crateCount == 1)
    #expect(!result.wasAlreadyCurrent)
    #expect(result.url.lastPathComponent.hasPrefix("snapshot-"))
    #expect(FileManager.default.fileExists(atPath: result.url.path))

    let readBack = try LibrarySnapshotBuilder.read(contentsOf: result.url)
    #expect(readBack.tracks.count == 2)
    #expect(readBack.crates[0].name == "Warmup")
}

/// Re-exporting an unchanged library must not rewrite the file — that would
/// re-upload the same megabytes for nothing.
@Test func exportingAnUnchangedLibraryIsANoOp() throws {
    let scratch = try makeExportScratch()
    defer { try? FileManager.default.removeItem(at: scratch.root) }

    let first = try LibrarySnapshotExportService.export(
        tracks: sampleTracks(), crates: [], libraryDirectory: scratch.libraryDirectory, to: scratch.destination)
    #expect(!first.wasAlreadyCurrent)

    let second = try LibrarySnapshotExportService.export(
        tracks: sampleTracks(), crates: [], libraryDirectory: scratch.libraryDirectory, to: scratch.destination)
    #expect(second.wasAlreadyCurrent)
    #expect(second.url == first.url)
    #expect(LibrarySnapshotExportService.existingSnapshots(in: scratch.destination).count == 1)
}

@Test func changingTheLibraryProducesANewSnapshotFile() throws {
    let scratch = try makeExportScratch()
    defer { try? FileManager.default.removeItem(at: scratch.root) }

    let first = try LibrarySnapshotExportService.export(
        tracks: sampleTracks(), crates: [], libraryDirectory: scratch.libraryDirectory, to: scratch.destination)

    // A different database means a different fingerprint, hence a new name.
    try Data("a much larger database".utf8)
        .write(to: SeratoLibraryLocator.databaseFile(in: scratch.libraryDirectory))

    let second = try LibrarySnapshotExportService.export(
        tracks: sampleTracks(), crates: [], libraryDirectory: scratch.libraryDirectory, to: scratch.destination)

    #expect(!second.wasAlreadyCurrent)
    #expect(second.url != first.url)
}

@Test func oldSnapshotsArePrunedButRecentOnesAreKept() throws {
    let scratch = try makeExportScratch()
    defer { try? FileManager.default.removeItem(at: scratch.root) }

    try FileManager.default.createDirectory(at: scratch.destination, withIntermediateDirectories: true)
    // Five stale snapshots, aged so their order is unambiguous.
    for index in 0..<5 {
        let url = scratch.destination.appendingPathComponent("snapshot-old\(index).json")
        try Data("{}".utf8).write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSince1970: 1_000_000 + Double(index) * 60)],
            ofItemAtPath: url.path
        )
    }

    let result = try LibrarySnapshotExportService.export(
        tracks: sampleTracks(),
        crates: [],
        libraryDirectory: scratch.libraryDirectory,
        to: scratch.destination,
        keeping: 3
    )

    let remaining = LibrarySnapshotExportService.existingSnapshots(in: scratch.destination)
    #expect(remaining.count == 3)
    #expect(remaining.contains(result.url))
    #expect(result.prunedURLs.count == 3)
}

/// A device that has been offline may still be holding work based on the
/// previous snapshot, so the newest is never the only one kept.
@Test func pruningKeepsThePreviousSnapshotForOfflineDevices() throws {
    let scratch = try makeExportScratch()
    defer { try? FileManager.default.removeItem(at: scratch.root) }

    let first = try LibrarySnapshotExportService.export(
        tracks: sampleTracks(), crates: [], libraryDirectory: scratch.libraryDirectory, to: scratch.destination)

    try Data("changed".utf8).write(to: SeratoLibraryLocator.databaseFile(in: scratch.libraryDirectory))
    let second = try LibrarySnapshotExportService.export(
        tracks: sampleTracks(), crates: [], libraryDirectory: scratch.libraryDirectory, to: scratch.destination)

    let remaining = LibrarySnapshotExportService.existingSnapshots(in: scratch.destination)
    #expect(remaining.contains(first.url))
    #expect(remaining.contains(second.url))
    #expect(remaining.first == second.url)
}

@Test func existingSnapshotsIgnoresUnrelatedFiles() throws {
    let scratch = try makeExportScratch()
    defer { try? FileManager.default.removeItem(at: scratch.root) }
    try FileManager.default.createDirectory(at: scratch.destination, withIntermediateDirectories: true)

    try Data("{}".utf8).write(to: scratch.destination.appendingPathComponent("snapshot-a.json"))
    try Data("{}".utf8).write(to: scratch.destination.appendingPathComponent("queue-b.json"))
    try Data("x".utf8).write(to: scratch.destination.appendingPathComponent("notes.txt"))

    let found = LibrarySnapshotExportService.existingSnapshots(in: scratch.destination)
    #expect(found.count == 1)
    #expect(found[0].lastPathComponent == "snapshot-a.json")
}

@Test func anUnwritableDestinationReportsAReadableError() throws {
    let scratch = try makeExportScratch()
    defer { try? FileManager.default.removeItem(at: scratch.root) }

    // A regular file where a folder needs to be.
    let blocker = scratch.root.appendingPathComponent("blocked")
    try Data("x".utf8).write(to: blocker)

    let error = #expect(throws: LibrarySnapshotExportService.ExportError.self) {
        try LibrarySnapshotExportService.export(
            tracks: sampleTracks(),
            crates: [],
            libraryDirectory: scratch.libraryDirectory,
            to: blocker.appendingPathComponent("nested", isDirectory: true)
        )
    }
    #expect(error?.errorDescription?.isEmpty == false)
    #expect(error?.recoverySuggestion?.isEmpty == false)
}
