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

/// Turns the key text Serato stores (`Am`, `8A`, `A min`, `C#`…) into the
/// classic key names a player's key column shows.
///
/// Names follow rekordbox's classic spelling: flats for the black keys
/// except F#, and a trailing `m` for minor. That spelling is from memory of
/// rekordbox's key table rather than from the rbxport reference, which
/// doesn't list the names.
enum CDJMusicalKey {
    private static let majors = ["C", "Db", "D", "Eb", "E", "F", "F#", "G", "Ab", "A", "Bb", "B"]
    private static let minors = ["Cm", "C#m", "Dm", "Ebm", "Em", "Fm", "F#m", "Gm", "G#m", "Am", "Bbm", "Bm"]

    /// Pitch classes (0 = C) by note letter, before any sharp or flat.
    private static let naturals: [Character: Int] = ["C": 0, "D": 2, "E": 4, "F": 5, "G": 7, "A": 9, "B": 11]

    /// Camelot wheel: number 1-12, `B` major, `A` minor. 8B = C major, 8A = A minor.
    private static let camelotMajor = [11, 6, 1, 8, 3, 10, 5, 0, 7, 2, 9, 4]
    private static let camelotMinor = [8, 3, 10, 5, 0, 7, 2, 9, 4, 11, 6, 1]

    /// nil when the text isn't a key we can read; the track then just has no key.
    static func classicName(from text: String?) -> String? {
        guard let raw = text?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if let camelot = camelot(raw) { return camelot }
        return spelledNote(raw)
    }

    private static func camelot(_ text: String) -> String? {
        let upper = text.uppercased()
        guard let letter = upper.last, letter == "A" || letter == "B",
              let number = Int(upper.dropLast()), (1...12).contains(number) else { return nil }
        return letter == "B" ? majors[camelotMajor[number - 1]] : minors[camelotMinor[number - 1]]
    }

    private static func spelledNote(_ text: String) -> String? {
        var characters = Array(text)
        guard let first = characters.first, let base = naturals[Character(first.uppercased())] else { return nil }
        characters.removeFirst()
        var pitch = base
        if let accidental = characters.first {
            if accidental == "#" || accidental == "♯" {
                pitch += 1
                characters.removeFirst()
            } else if accidental == "b" || accidental == "♭" {
                pitch -= 1
                characters.removeFirst()
            }
        }
        let quality = String(characters).trimmingCharacters(in: .whitespaces).lowercased()
        let isMinor: Bool
        switch quality {
        case "", "maj", "major": isMinor = false
        case "m", "min", "minor": isMinor = true
        default: return nil
        }
        let index = (pitch % 12 + 12) % 12
        return isMinor ? minors[index] : majors[index]
    }
}
