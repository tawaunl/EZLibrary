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

/// Builds a throwaway directory shaped like a Serato library.
private func makeLibrary() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ezlibrary-fingerprint-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: SeratoLibraryLocator.subcratesDirectory(in: directory),
        withIntermediateDirectories: true
    )
    try Data("db".utf8).write(to: SeratoLibraryLocator.databaseFile(in: directory))
    return directory
}

private func writeCrate(_ name: String, contents: String, in directory: URL) throws {
    try Data(contents.utf8).write(
        to: SeratoLibraryLocator.subcratesDirectory(in: directory)
            .appendingPathComponent("\(name).crate")
    )
}

@Test func fingerprintIsStableForAnUnchangedLibrary() throws {
    let directory = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeCrate("Disco", contents: "aaa", in: directory)

    let first = LibraryFingerprint.compute(libraryDirectory: directory)
    let second = LibraryFingerprint.compute(libraryDirectory: directory)
    #expect(first == second)
    #expect(!first.isEmpty)
}

@Test func fingerprintChangesWhenTheDatabaseChangesSize() throws {
    let directory = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: directory) }

    let before = LibraryFingerprint.compute(libraryDirectory: directory)
    try Data("a much longer database body".utf8)
        .write(to: SeratoLibraryLocator.databaseFile(in: directory))
    #expect(LibraryFingerprint.compute(libraryDirectory: directory) != before)
}

@Test func fingerprintChangesWhenACrateIsAdded() throws {
    let directory = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: directory) }

    let before = LibraryFingerprint.compute(libraryDirectory: directory)
    try writeCrate("Warmup", contents: "one", in: directory)
    #expect(LibraryFingerprint.compute(libraryDirectory: directory) != before)
}

/// Deleting a crate has to move the fingerprint too, which is why missing
/// files contribute an "absent" marker rather than being skipped.
@Test func fingerprintChangesWhenACrateIsRemoved() throws {
    let directory = try makeLibrary()
    defer { try? FileManager.default.removeItem(at: directory) }
    try writeCrate("Warmup", contents: "one", in: directory)

    let before = LibraryFingerprint.compute(libraryDirectory: directory)
    try FileManager.default.removeItem(
        at: SeratoLibraryLocator.subcratesDirectory(in: directory).appendingPathComponent("Warmup.crate")
    )
    #expect(LibraryFingerprint.compute(libraryDirectory: directory) != before)
}

@Test func fingerprintOfAMissingLibraryIsStableRatherThanACrash() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ezlibrary-absent-\(UUID().uuidString)", isDirectory: true)
    let first = LibraryFingerprint.compute(libraryDirectory: directory)
    #expect(first == LibraryFingerprint.compute(libraryDirectory: directory))
}

@Test func hashIsDeterministicAndDiffersByInput() {
    #expect(LibraryFingerprint.hash("abc") == LibraryFingerprint.hash("abc"))
    #expect(LibraryFingerprint.hash("abc") != LibraryFingerprint.hash("abd"))
    #expect(LibraryFingerprint.hash("").count == 16)
}
