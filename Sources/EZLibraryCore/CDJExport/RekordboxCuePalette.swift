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

/// The fixed set of cue colours a CDJ draws, indexed by colour code.
/// Serato lets a cue be any RGB value, so each one is matched to the nearest.
enum RekordboxCuePalette {
    /// Colour code to RGB, as captured from rekordbox exports.
    static let rgb: [UInt32] = [
        0x000000, 0x0000FF, 0x001CFF, 0x0038FF, 0x0054FF, 0x0070FF, 0x008CFF, 0x00A8FF,
        0x00C4FF, 0x00E0FF, 0x00FFFF, 0x00FFE8, 0x00FFD1, 0x00FFBA, 0x00FFA3, 0x00FF8C,
        0x00FF75, 0x00FF5E, 0x00FF47, 0x00FF30, 0x00FF1A, 0x00FF00, 0x1AFF00, 0x33FF00,
        0x4DFF00, 0x66FF00, 0x80FF00, 0x99FF00, 0xB3FF00, 0xCCFF00, 0xE6FF00, 0xFFFF00,
        0xFFE800, 0xFFD100, 0xFFBA00, 0xFFA300, 0xFF8C00, 0xFF7500, 0xFF5E00, 0xFF4700,
        0xFF3000, 0xFF1A00, 0xFF0000, 0xFF0017, 0xFF002E, 0xFF0045, 0xFF005C, 0xFF0073,
        0xFF008A, 0xFF00A1, 0xFF00B8, 0xFF00CF, 0xFF00E6, 0xFF00FF, 0xE600FF, 0xCC00FF,
        0xB300FF, 0x9900FF, 0x8000FF, 0x6600FF, 0x4D00FF, 0x3300FF, 0x1A00FF, 0x000000,
        0xFFFFFF
    ]

    /// Codes worth choosing: not 0 (which means "use the slot's default") and
    /// not 63, which is black.
    private static let selectable = Array(1...62) + [64]

    /// The palette code whose colour is closest to `color`, and that colour's RGB.
    static func nearest(to color: SeratoTrackAnalysis.RGB) -> (code: UInt8, red: UInt8, green: UInt8, blue: UInt8) {
        func distance(_ code: Int) -> Int {
            let value = rgb[code]
            let dr = Int(value >> 16 & 0xFF) - Int(color.red)
            let dg = Int(value >> 8 & 0xFF) - Int(color.green)
            let db = Int(value & 0xFF) - Int(color.blue)
            return dr * dr + dg * dg + db * db
        }
        let best = selectable.min { distance($0) < distance($1) } ?? 1
        let value = rgb[best]
        return (UInt8(best), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF))
    }
}
