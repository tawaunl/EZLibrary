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
import AVFoundation
@testable import EZLibraryCore

@Suite(.serialized)
struct TrackAudioEditServiceTests {

    private struct Env {
        let root: URL
        let libraryDirectory: URL
        let musicDirectory: URL
        let databaseFileURL: URL
        let rootDirectory: URL
        let track: Track
    }

    /// A small library holding one real MP3, listed in `database V2` and in
    /// two plain crates plus one smart crate.
    private func makeLibrary(toneSeconds: Double = 6) throws -> Env? {
        guard let ffmpeg = AudioTrimService.ffmpegExecutablePath() else { return nil }

        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("audio-edit-\(UUID().uuidString)", isDirectory: true)
        let libraryDirectory = root.appendingPathComponent("_Serato_", isDirectory: true)
        let musicDirectory = root.appendingPathComponent("Music", isDirectory: true)
        for directory in [
            libraryDirectory.appendingPathComponent("Subcrates", isDirectory: true),
            libraryDirectory.appendingPathComponent("SmartCrates", isDirectory: true),
            musicDirectory
        ] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }
        TestBackupDirectory.use()

        let audioURL = musicDirectory.appendingPathComponent("Test Artist - Test Title.mp3")
        let process = Process()
        process.executableURL = URL(fileURLWithPath: ffmpeg)
        process.arguments = [
            "-hide_banner", "-loglevel", "error", "-y",
            "-f", "lavfi", "-i", "sine=frequency=440:duration=\(toneSeconds)",
            "-ar", "44100", "-ac", "2", "-c:a", "libmp3lame", "-b:a", "128k",
            audioURL.path
        ]
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }

        let rootDirectory = SeratoLibraryLocator.rootDirectory(for: libraryDirectory, homeDirectory: root)
        let storedPath = SeratoLibraryLocator.seratoStoredPath(for: audioURL, rootDirectory: rootDirectory)

        let databaseData = SeratoDatabaseWriter.ensuringTrackExists(
            forStoredPath: storedPath,
            metadata: SeratoTrackMetadataUpdate(
                title: "Test Title", artist: "Test Artist", album: "Test Album",
                genre: "House", comment: "", key: "8A", bpm: 128, year: 2026),
            in: Data()
        ).data
        let databaseFileURL = SeratoLibraryLocator.databaseFile(in: libraryDirectory)
        try databaseData.write(to: databaseFileURL)

        // Two plain crates carry the track; a third does not.
        let subcrates = libraryDirectory.appendingPathComponent("Subcrates", isDirectory: true)
        try SeratoCrateWriter.makeCrateData(trackPaths: [storedPath])
            .write(to: subcrates.appendingPathComponent("Bangers.crate"))
        try SeratoCrateWriter.makeCrateData(trackPaths: ["Music/Other.mp3", storedPath])
            .write(to: subcrates.appendingPathComponent("House.crate"))
        try SeratoCrateWriter.makeCrateData(trackPaths: ["Music/Other.mp3"])
            .write(to: subcrates.appendingPathComponent("Unrelated.crate"))

        let track = Track(
            seratoStoredPath: storedPath,
            fileURL: audioURL,
            title: "Test Title",
            artist: "Test Artist",
            album: "Test Album",
            genre: "House",
            bpm: 128,
            key: "8A"
        )

        return Env(
            root: root,
            libraryDirectory: libraryDirectory,
            musicDirectory: musicDirectory,
            databaseFileURL: databaseFileURL,
            rootDirectory: rootDirectory,
            track: track
        )
    }

    private func duration(of url: URL) async throws -> Double {
        try await AVURLAsset(url: url).load(.duration).seconds
    }

    // MARK: - Save in place

    @Test func saveInPlaceTrimsTheFileWithoutTouchingTheLibrary() async throws {
        guard let env = try makeLibrary() else { return }
        defer { try? FileManager.default.removeItem(at: env.root) }

        let databaseBefore = try Data(contentsOf: env.databaseFileURL)

        let result = try TrackAudioEditService.saveInPlace(
            track: env.track, startSeconds: 1, endSeconds: 4)

        #expect(result.replacedOriginal)
        #expect(result.newStoredPath == nil)
        #expect(result.cratesUpdated.isEmpty)
        #expect(abs(try await duration(of: env.track.fileURL) - 3) < 0.15)

        // The path never changed, so nothing in Serato's library should have.
        #expect(try Data(contentsOf: env.databaseFileURL) == databaseBefore)
    }

    @Test func saveInPlaceRefusesWhileSeratoIsRunning() throws {
        guard let env = try makeLibrary() else { return }
        defer {
            TestSeratoEnvironment.pretendSeratoIsClosed()
            try? FileManager.default.removeItem(at: env.root)
        }

        let bytesBefore = try Data(contentsOf: env.track.fileURL)

        TestSeratoEnvironment.withSeratoRunning {
            #expect(throws: TrackAudioEditService.EditError.self) {
                try TrackAudioEditService.saveInPlace(
                    track: env.track, startSeconds: 1, endSeconds: 4)
            }
        }
        #expect(try Data(contentsOf: env.track.fileURL) == bytesBefore)
    }

    // MARK: - Save as a new file

    @Test func saveAsNewFileRegistersTheEditAndKeepsTheOriginal() async throws {
        guard let env = try makeLibrary() else { return }
        defer { try? FileManager.default.removeItem(at: env.root) }

        let originalBytes = try Data(contentsOf: env.track.fileURL)
        let destination = AudioTrimService.suggestedEditURL(for: env.track.fileURL)

        let result = try TrackAudioEditService.saveAsNewFile(
            track: env.track,
            startSeconds: 2,
            endSeconds: 5,
            destinationURL: destination,
            libraryDirectory: env.libraryDirectory
        )

        #expect(!result.replacedOriginal)
        #expect(result.addedToDatabase)
        #expect(destination.lastPathComponent == "Test Artist - Test Title (Edit).mp3")
        #expect(try Data(contentsOf: env.track.fileURL) == originalBytes)
        #expect(abs(try await duration(of: destination) - 3) < 0.15)

        // The new path is in database V2, alongside the original.
        let storedPaths = SeratoDatabaseParser.storedPaths(from: try Data(contentsOf: env.databaseFileURL))
        let newStoredPath = try #require(result.newStoredPath)
        #expect(storedPaths.contains(newStoredPath))
        #expect(storedPaths.contains(env.track.seratoStoredPath))
    }

    @Test func saveAsNewFileAddsTheEditToEveryCrateHoldingTheOriginal() throws {
        guard let env = try makeLibrary() else { return }
        defer { try? FileManager.default.removeItem(at: env.root) }

        let destination = AudioTrimService.suggestedEditURL(for: env.track.fileURL)
        let result = try TrackAudioEditService.saveAsNewFile(
            track: env.track,
            startSeconds: 0,
            endSeconds: 3,
            destinationURL: destination,
            libraryDirectory: env.libraryDirectory
        )

        #expect(Set(result.cratesUpdated) == ["Bangers", "House"])

        // The edit files directly after the track it came from, not at the end.
        let subcrates = env.libraryDirectory.appendingPathComponent("Subcrates", isDirectory: true)
        let housePaths = SeratoCrateParser.trackPaths(
            from: try Data(contentsOf: subcrates.appendingPathComponent("House.crate")))
        let newStoredPath = try #require(result.newStoredPath)
        #expect(housePaths == ["Music/Other.mp3", env.track.seratoStoredPath, newStoredPath])

        // A crate that never held the original is left alone.
        let unrelatedPaths = SeratoCrateParser.trackPaths(
            from: try Data(contentsOf: subcrates.appendingPathComponent("Unrelated.crate")))
        #expect(unrelatedPaths == ["Music/Other.mp3"])
    }

    @Test func saveAsNewFileCanSkipCrateMembership() throws {
        guard let env = try makeLibrary() else { return }
        defer { try? FileManager.default.removeItem(at: env.root) }

        let result = try TrackAudioEditService.saveAsNewFile(
            track: env.track,
            startSeconds: 0,
            endSeconds: 3,
            destinationURL: AudioTrimService.suggestedEditURL(for: env.track.fileURL),
            libraryDirectory: env.libraryDirectory,
            addToCratesContainingOriginal: false
        )

        #expect(result.cratesUpdated.isEmpty)

        let subcrates = env.libraryDirectory.appendingPathComponent("Subcrates", isDirectory: true)
        let bangers = SeratoCrateParser.trackPaths(
            from: try Data(contentsOf: subcrates.appendingPathComponent("Bangers.crate")))
        #expect(bangers == [env.track.seratoStoredPath])
    }

    /// The edit inherits the original's tags so it's identifiable in Serato's
    /// browser before it has been analyzed.
    @Test func saveAsNewFileCarriesTheOriginalTagsOntoTheNewRecord() throws {
        guard let env = try makeLibrary() else { return }
        defer { try? FileManager.default.removeItem(at: env.root) }

        let result = try TrackAudioEditService.saveAsNewFile(
            track: env.track,
            startSeconds: 0,
            endSeconds: 3,
            destinationURL: AudioTrimService.suggestedEditURL(for: env.track.fileURL),
            libraryDirectory: env.libraryDirectory
        )

        let newStoredPath = try #require(result.newStoredPath)
        let tracks = try SeratoDatabaseParser.parseTracks(
            at: env.databaseFileURL, rootDirectory: env.rootDirectory)
        let edited = try #require(tracks.first { $0.seratoStoredPath == newStoredPath })

        #expect(edited.title == "Test Title")
        #expect(edited.artist == "Test Artist")
        #expect(edited.album == "Test Album")
        #expect(edited.bpm == 128)
    }

    @Test func saveAsNewFileRefusesWhileSeratoIsRunning() throws {
        guard let env = try makeLibrary() else { return }
        defer {
            TestSeratoEnvironment.pretendSeratoIsClosed()
            try? FileManager.default.removeItem(at: env.root)
        }

        let destination = AudioTrimService.suggestedEditURL(for: env.track.fileURL)

        TestSeratoEnvironment.withSeratoRunning {
            #expect(throws: TrackAudioEditService.EditError.self) {
                try TrackAudioEditService.saveAsNewFile(
                    track: env.track, startSeconds: 0, endSeconds: 3,
                    destinationURL: destination, libraryDirectory: env.libraryDirectory)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    /// Running the same edit twice must not list the file in a crate twice.
    @Test func addingToCratesIsIdempotent() throws {
        guard let env = try makeLibrary() else { return }
        defer { try? FileManager.default.removeItem(at: env.root) }

        let newStoredPath = "Music/Test Artist - Test Title (Edit).mp3"
        let first = try TrackAudioEditService.addToCrates(
            containing: env.track.seratoStoredPath,
            newStoredPath: newStoredPath,
            libraryDirectory: env.libraryDirectory)
        let second = try TrackAudioEditService.addToCrates(
            containing: env.track.seratoStoredPath,
            newStoredPath: newStoredPath,
            libraryDirectory: env.libraryDirectory)

        #expect(Set(first) == ["Bangers", "House"])
        #expect(second.isEmpty)

        let subcrates = env.libraryDirectory.appendingPathComponent("Subcrates", isDirectory: true)
        let bangers = SeratoCrateParser.trackPaths(
            from: try Data(contentsOf: subcrates.appendingPathComponent("Bangers.crate")))
        #expect(bangers.filter { $0 == newStoredPath }.count == 1)
    }
}
