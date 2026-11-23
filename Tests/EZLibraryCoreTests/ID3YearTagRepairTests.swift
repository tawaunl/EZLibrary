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

struct ID3YearTagRepairTests {
    private func syncSafe(_ v: Int) -> [UInt8] {
        [UInt8((v >> 21) & 0x7F), UInt8((v >> 14) & 0x7F), UInt8((v >> 7) & 0x7F), UInt8(v & 0x7F)]
    }

    private func frame(_ id: String, _ text: String) -> Data {
        let payload = Data([0x03]) + Data(text.utf8)
        return Data(id.utf8) + Data(syncSafe(payload.count)) + Data([0, 0]) + payload
    }

    private func makeMP3(version: UInt8 = 4, frames: [Data]) throws -> URL {
        let body = frames.reduce(Data(), +) + Data(repeating: 0, count: 16) // padding
        var file = Data([0x49, 0x44, 0x33, version, 0, 0]) + Data(syncSafe(body.count)) + body
        file.append(Data(repeating: 0xFF, count: 32)) // stand-in audio
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("yearrepair-\(UUID().uuidString).mp3")
        try file.write(to: url)
        return url
    }

    @Test func renamesTYERToTDRCWithoutTouchingAnythingElse() throws {
        let url = try makeMP3(frames: [frame("TIT2", "Song"), frame("TYER", "2012")])
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)

        #expect(ID3YearTagRepair.needsRepair(fileURL: url))
        #expect(try ID3YearTagRepair.repair(fileURL: url) == .repaired)

        let after = try Data(contentsOf: url)
        #expect(after.count == before.count)
        #expect(after.range(of: Data("TYER".utf8)) == nil)
        #expect(after.range(of: Data("TDRC".utf8)) != nil)
        #expect(!ID3YearTagRepair.needsRepair(fileURL: url))
        #expect(try ID3YearTagRepair.repair(fileURL: url) == .notNeeded)
    }

    @Test func leavesGenuineV23TagsAlone() throws {
        let url = try makeMP3(version: 3, frames: [frame("TYER", "2012")])
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)

        #expect(try ID3YearTagRepair.repair(fileURL: url) == .notNeeded)
        #expect(try Data(contentsOf: url) == before)
    }

    @Test func keepsExistingTDRC() throws {
        let url = try makeMP3(frames: [frame("TDRC", "2015"), frame("TYER", "2012")])
        defer { try? FileManager.default.removeItem(at: url) }
        let before = try Data(contentsOf: url)

        #expect(try ID3YearTagRepair.repair(fileURL: url) == .alreadyHasTDRC)
        #expect(try Data(contentsOf: url) == before)
    }
}
