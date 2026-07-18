import Foundation

/// Shared, pure helpers for building record-pool search queries and confirming
/// that a returned result actually matches the requested track (so pools, like
/// the Buy stores, only ever surface confirmed hits).
enum RecordPoolMatch {
    static func query(title: String, artist: String) -> String {
        [artist, title]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// Keeps only results whose title reasonably matches the requested title
    /// (order-independent normalized containment) and, when both sides have an
    /// artist, whose artist overlaps too.
    static func confirmed(
        _ results: [RecordPoolResult],
        title: String,
        artist: String,
        limit: Int
    ) -> [RecordPoolResult] {
        let wantedTitle = normalized(title)
        let wantedArtist = normalized(artist)
        guard !wantedTitle.isEmpty else { return [] }

        var output: [RecordPoolResult] = []
        for result in results {
            let resultTitle = normalized(result.title)
            guard !resultTitle.isEmpty, containsEither(resultTitle, wantedTitle) else { continue }

            let resultArtist = normalized(result.artist)
            if !wantedArtist.isEmpty, !resultArtist.isEmpty, !containsEither(resultArtist, wantedArtist) {
                continue
            }

            output.append(result)
            if output.count >= limit { break }
        }
        return output
    }

    static func normalized(_ value: String) -> String {
        let lowered = value.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let scalars = lowered.unicodeScalars.map { scalar -> Character in
            (CharacterSet.alphanumerics.contains(scalar)) ? Character(scalar) : " "
        }
        return String(scalars)
            .split(separator: " ")
            .joined(separator: " ")
    }

    private static func containsEither(_ a: String, _ b: String) -> Bool {
        a == b || a.contains(b) || b.contains(a)
    }
}
