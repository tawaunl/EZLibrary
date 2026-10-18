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

/// Where a track's ANLZ files live. A CDJ computes the folder itself from the
/// track's audio path, so pointing the database at any other folder leaves
/// its waveforms unloaded.
public enum RekordboxAnalysisPath {
    /// The hash a CDJ-3000 (firmware 3.20) derives from the leading-slash audio
    /// path, case preserved: `h = h * 0x34F5501D + unit * 0x93B6` over its UTF-16
    /// code units, taken modulo `0x30D43`.
    static func hash(forAudioPath path: String) -> UInt32 {
        var value: UInt32 = 0
        for unit in path.utf16 {
            if unit == 0 { break }
            value = value &* 0x34F5_501D &+ UInt32(unit) &* 0x93B6
        }
        return value % 0x30D43
    }

    /// Hash bits that make up the shard number, from the lowest shard bit up.
    private static let shardBits = [0, 2, 6, 7, 9, 13, 16]

    /// `/PIONEER/USBANLZ/P###/########/ANLZ0000.DAT` for the audio file at `audioPath`.
    public static func datPath(forAudioPath audioPath: String, root: String = "PIONEER") -> String {
        let hash = hash(forAudioPath: audioPath)
        var shard: UInt32 = 0
        for (position, bit) in shardBits.enumerated() {
            shard |= ((hash >> UInt32(bit)) & 1) << UInt32(position)
        }
        return String(format: "/%@/USBANLZ/P%03X/%08X/ANLZ0000.DAT", root, shard, hash)
    }
}
