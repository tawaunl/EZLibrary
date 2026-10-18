// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Compression
import Foundation

/// The passphrase `exportLibrary.db` is encrypted with.
///
/// It is the same on every stick, because any machine has to be able to read an
/// export; it protects nothing. rekordbox carries it obfuscated as a base85
/// string, XORed with a short key and zlib-compressed. The constants are the ones
/// the pyrekordbox project documents, and the result is checked against its known
/// prefix so a wrong constant fails here rather than as an unreadable database.
/// The passphrase is never logged or shown.
enum OneLibraryKey {
    private static let blob = "PN_1dH8$oLJY)16j_RvM6qphWw`476>;C1cWmI#se(PG`j}~xAjlufj?`#0i{;=glh(SkW)y0>n?YEiD`l%t("
    private static let xorKey = Array("657f48f84c437cc1".utf8)
    private static let expectedPrefix = "r8gd"
    /// RFC 1924 base85, which is not the Ascii85 alphabet.
    private static let alphabet = Array(
        "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz!#$%&()*+-;<=>?@^_`{|}~".utf8)

    static func passphrase() throws -> String {
        let decoded = try base85Decode(blob)
        let unmasked = decoded.enumerated().map { $0.element ^ xorKey[$0.offset % xorKey.count] }
        // A zlib stream is a two-byte header, raw deflate data and a four-byte checksum;
        // Compression's .zlib algorithm takes the raw deflate data alone.
        guard unmasked.count > 6 else { throw CDJExportError.verificationFailed("The library key is damaged.") }
        let deflated = Data(unmasked[2..<(unmasked.count - 4)])
        guard let inflated = try? (deflated as NSData).decompressed(using: .zlib) as Data,
              let key = String(data: inflated, encoding: .utf8), key.hasPrefix(expectedPrefix) else {
            throw CDJExportError.verificationFailed("The library key is damaged.")
        }
        return key
    }

    private static func base85Decode(_ text: String) throws -> [UInt8] {
        var output: [UInt8] = []
        let characters = Array(text.utf8)
        for start in stride(from: 0, to: characters.count, by: 5) {
            let group = characters[start..<min(start + 5, characters.count)]
            var value: UInt64 = 0
            for character in group {
                guard let digit = alphabet.firstIndex(of: character) else {
                    throw CDJExportError.verificationFailed("The library key is damaged.")
                }
                value = value * 85 + UInt64(digit)
            }
            // A short final group carries one byte fewer than its length.
            let bytes = [UInt8((value >> 24) & 0xff), UInt8((value >> 16) & 0xff), UInt8((value >> 8) & 0xff), UInt8(value & 0xff)]
            output.append(contentsOf: bytes.prefix(group.count == 5 ? 4 : group.count - 1))
        }
        return output
    }
}
