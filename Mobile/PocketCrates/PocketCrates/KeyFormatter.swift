import Foundation

/// Converts any Serato key string to Camelot (Harmonic Mixing) notation.
///
/// Serato can store keys in three formats depending on user settings:
/// already-Camelot ("4A"), Open Key ("5m"), or musical notation ("Fm").
/// This normalises all three to Camelot so the UI always shows one format.
enum KeyFormatter {
    static func camelot(from raw: String) -> String {
        let s = raw.trimmingCharacters(in: .whitespaces)
        guard !s.isEmpty else { return raw }

        // Already Camelot — 1A–12A or 1B–12B
        if s.range(of: #"^(1[0-2]|[1-9])[ABab]$"#, options: .regularExpression) != nil {
            return s.uppercased()
        }

        // Open Key — same number, m→A d→B (e.g. "5m" → "5A")
        if s.range(of: #"^(1[0-2]|[1-9])[mMdD]$"#, options: .regularExpression) != nil,
           let suffix = s.last {
            return "\(s.dropLast())\(suffix == "m" || suffix == "M" ? "A" : "B")"
        }

        // Musical notation (C, Fm, C#m, Ab, Dbm, …)
        return musicalToCamelot(s) ?? raw
    }

    // MARK: - Musical → Camelot

    private static func musicalToCamelot(_ raw: String) -> String? {
        var s = raw.lowercased()
            .replacingOccurrences(of: " ", with: "")
            .replacingOccurrences(of: "major", with: "")
            .replacingOccurrences(of: "minor", with: "m")
            .replacingOccurrences(of: "maj", with: "")
            .replacingOccurrences(of: "min", with: "m")

        let isMinor = s.hasSuffix("m") && !s.hasSuffix("maj")
        if isMinor { s = String(s.dropLast()) }

        // Camelot outer ring (B = major)
        let major: [String: Int] = [
            "c": 8,  "g": 9,  "d": 10, "a": 11, "e": 12,
            "b": 1,  "cb": 1,
            "f#": 2, "gb": 2,
            "c#": 3, "db": 3,
            "ab": 4, "g#": 4,
            "eb": 5, "d#": 5,
            "bb": 6, "a#": 6,
            "f": 7,
        ]

        // Camelot inner ring (A = minor)
        let minor: [String: Int] = [
            "c": 5,  "g": 6,  "d": 7,  "a": 8,  "e": 9,
            "b": 10,
            "f#": 11, "gb": 11,
            "c#": 12, "db": 12,
            "g#": 1,  "ab": 1,
            "d#": 2,  "eb": 2,
            "a#": 3,  "bb": 3,
            "f": 4,
        ]

        if isMinor, let n = minor[s] { return "\(n)A" }
        if !isMinor, let n = major[s] { return "\(n)B" }
        return nil
    }
}
