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

/// `PIONEER/DEVSETTING.DAT`: the player display preferences a stick carries.
///
/// A stick without one is read with defaults, but rekordbox always writes
/// it, so we create it when it's missing. An existing file is the DJ's own
/// settings and is never touched. Layout from the rbxport reference (140
/// bytes, checked there against a rekordbox 7.2.8 export).
enum CDJDeviceSettingsFile {
    static let fileName = "DEVSETTING.DAT"
    static let length = 140

    /// rekordbox's defaults: Half overview, Blue waveform, Classic key display, Centre position.
    private static let body: [UInt8] = [
        0x78, 0x56, 0x34, 0x12, 0x01, 0x00, 0x00, 0x00, 0x01, 0x01, 0x01, 0x01, 0x01, 0x01
    ] + [UInt8](repeating: 0, count: 18)

    static func data(version: String = "7.2.11") -> Data {
        var data = Data()
        data.appendLE(UInt32(0x60))
        data.append(padded("PIONEER DJ"))
        data.append(padded("rekordbox"))
        data.append(padded(version))
        data.appendLE(UInt32(body.count))
        data.append(contentsOf: body)
        data.appendLE(crc16XModem(body))
        data.appendLE(UInt16(0))
        return data
    }

    private static func padded(_ text: String) -> Data {
        var bytes = Array(text.utf8.prefix(31))
        bytes += [UInt8](repeating: 0, count: 32 - bytes.count)
        return Data(bytes)
    }

    /// CRC-16/XMODEM: polynomial 0x1021, no reflection, initial value 0.
    static func crc16XModem(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = crc & 0x8000 == 0 ? crc << 1 : (crc << 1) ^ 0x1021
            }
        }
        return crc
    }
}
