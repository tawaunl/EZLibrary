import Foundation

public struct DuplicateTrackGroup: Identifiable, Hashable, Sendable {
    public let id: String
    public let artist: String
    public let title: String
    public let versionLabel: String
    public let tracks: [Track]

    public var trackCount: Int {
        tracks.count
    }

    public var redundantTrackCount: Int {
        max(0, tracks.count - 1)
    }

    /// Number of distinct audio filenames (case-insensitive) across the group.
    public var uniqueFilenameCount: Int {
        Set(tracks.map { $0.fileURL.lastPathComponent.lowercased() }).count
    }

    /// True when the duplicates point at different filenames on disk, rather
    /// than the same filename referenced more than once. Useful for telling
    /// genuinely separate duplicate files apart from repeated references to
    /// one file.
    public var hasDifferentFilenames: Bool {
        uniqueFilenameCount > 1
    }

    public init(id: String, artist: String, title: String, versionLabel: String, tracks: [Track]) {
        self.id = id
        self.artist = artist
        self.title = title
        self.versionLabel = versionLabel
        self.tracks = tracks
    }
}

public struct DuplicateTracksSummary: Sendable {
    public let totalTracks: Int
    public let duplicateGroupCount: Int
    public let redundantTrackCount: Int
    public let versionSeparatedGroupCount: Int

    public init(
        totalTracks: Int,
        duplicateGroupCount: Int,
        redundantTrackCount: Int,
        versionSeparatedGroupCount: Int
    ) {
        self.totalTracks = totalTracks
        self.duplicateGroupCount = duplicateGroupCount
        self.redundantTrackCount = redundantTrackCount
        self.versionSeparatedGroupCount = versionSeparatedGroupCount
    }
}

public enum DuplicateTracksService {
    public static func summary(for tracks: [Track]) -> DuplicateTracksSummary {
        summary(forGroups: duplicateGroups(in: tracks), totalTracks: tracks.count)
    }

    /// Derives the summary from already-computed groups, so callers that
    /// need both don't pay for the full duplicate scan twice.
    public static func summary(forGroups groups: [DuplicateTrackGroup], totalTracks: Int) -> DuplicateTracksSummary {
        DuplicateTracksSummary(
            totalTracks: totalTracks,
            duplicateGroupCount: groups.count,
            redundantTrackCount: groups.reduce(0) { $0 + $1.redundantTrackCount },
            versionSeparatedGroupCount: groups.filter { $0.versionLabel != VersionCategory.original.displayName }.count
        )
    }

    public static func duplicateGroups(in tracks: [Track]) -> [DuplicateTrackGroup] {
        let grouped = Dictionary(grouping: tracks.compactMap(makeCandidate), by: \.groupKey)

        return grouped.values.compactMap { candidates in
            guard candidates.count > 1 else { return nil }

            let sortedTracks = candidates
                .map(\.track)
                .sorted { lhs, rhs in
                    let leftTitle = lhs.title.isEmpty ? lhs.fileURL.lastPathComponent : lhs.title
                    let rightTitle = rhs.title.isEmpty ? rhs.fileURL.lastPathComponent : rhs.title
                    let titleOrder = leftTitle.localizedStandardCompare(rightTitle)
                    if titleOrder != .orderedSame {
                        return titleOrder == .orderedAscending
                    }

                    let artistOrder = lhs.artist.localizedStandardCompare(rhs.artist)
                    if artistOrder != .orderedSame {
                        return artistOrder == .orderedAscending
                    }

                    return lhs.seratoStoredPath.localizedStandardCompare(rhs.seratoStoredPath) == .orderedAscending
                }

            let representative = candidates.first!
            return DuplicateTrackGroup(
                id: representative.groupKey,
                artist: representative.artistDisplay,
                title: representative.titleDisplay,
                versionLabel: representative.version.displayName,
                tracks: sortedTracks
            )
        }
        .sorted { lhs, rhs in
            if lhs.redundantTrackCount != rhs.redundantTrackCount {
                return lhs.redundantTrackCount > rhs.redundantTrackCount
            }

            let artistOrder = lhs.artist.localizedStandardCompare(rhs.artist)
            if artistOrder != .orderedSame {
                return artistOrder == .orderedAscending
            }

            let titleOrder = lhs.title.localizedStandardCompare(rhs.title)
            if titleOrder != .orderedSame {
                return titleOrder == .orderedAscending
            }

            return lhs.versionLabel.localizedStandardCompare(rhs.versionLabel) == .orderedAscending
        }
    }

    public static func versionLabel(for track: Track) -> String {
        versionCategory(for: titleSource(for: track)).displayName
    }

    /// Counts how many meaningful ID3/metadata fields a track has populated.
    /// Higher means more complete tag information.
    public static func completenessScore(for track: Track) -> Int {
        var score = 0

        let textFields = [
            track.title,
            track.artist,
            track.album,
            track.genre,
            track.comment,
            track.grouping,
            track.label
        ]
        for field in textFields where !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            score += 1
        }

        if track.year != nil { score += 1 }
        if let bpm = track.bpm, bpm > 0 { score += 1 }
        if let key = track.key, !key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { score += 1 }
        if track.trackNumber != nil { score += 1 }

        return score
    }

    /// Orders a group's tracks best-first: most complete ID3 tags win, ties go
    /// to the oldest `dateAdded`, and a final stable tie-break keeps ordering
    /// deterministic. The first element is the recommended track to keep.
    public static func rankedTracks(in tracks: [Track]) -> [Track] {
        tracks.sorted(by: isBetterCandidate)
    }

    /// The recommended track to keep for a set of duplicates: most complete
    /// tags, breaking ties toward the oldest `dateAdded`.
    public static func bestTrack(in tracks: [Track]) -> Track? {
        rankedTracks(in: tracks).first
    }

    /// The tracks that would be removed if the best track is kept.
    public static func redundantTracks(in tracks: [Track]) -> [Track] {
        Array(rankedTracks(in: tracks).dropFirst())
    }

    private static func isBetterCandidate(_ lhs: Track, _ rhs: Track) -> Bool {
        let lhsScore = completenessScore(for: lhs)
        let rhsScore = completenessScore(for: rhs)
        if lhsScore != rhsScore {
            return lhsScore > rhsScore
        }

        // Tie: prefer the oldest track by date added. A missing date is treated
        // as the most recent so a track with a known date wins.
        let lhsDate = lhs.dateAdded ?? .distantFuture
        let rhsDate = rhs.dateAdded ?? .distantFuture
        if lhsDate != rhsDate {
            return lhsDate < rhsDate
        }

        return lhs.seratoStoredPath.localizedStandardCompare(rhs.seratoStoredPath) == .orderedAscending
    }

    private struct Candidate {
        let track: Track
        let artistDisplay: String
        let titleDisplay: String
        let version: VersionCategory
        let groupKey: String
    }

    private enum VersionCategory: String, CaseIterable {
        case original
        case intro
        case extended
        case clean
        case dirty
        case radio
        case instrumental
        case acapella
        case quickHit
        case vip
        case remix
        case edit
        case mix
        case club
        case bootleg
        case rework
        case outro
        case live
        case demo
        case other

        var displayName: String {
            switch self {
            case .original:
                return "Original"
            case .intro:
                return "Intro"
            case .extended:
                return "Extended"
            case .clean:
                return "Clean"
            case .dirty:
                return "Dirty"
            case .radio:
                return "Radio"
            case .instrumental:
                return "Instrumental"
            case .acapella:
                return "Acapella"
            case .quickHit:
                return "Quick Hit"
            case .vip:
                return "VIP"
            case .remix:
                return "Remix"
            case .edit:
                return "Edit"
            case .mix:
                return "Mix"
            case .club:
                return "Club"
            case .bootleg:
                return "Bootleg"
            case .rework:
                return "Rework"
            case .outro:
                return "Outro"
            case .live:
                return "Live"
            case .demo:
                return "Demo"
            case .other:
                return "Other"
            }
        }
    }

    private static func makeCandidate(for track: Track) -> Candidate? {
        let title = titleSource(for: track)
        let titleKey = normalizedTitle(title)
        let artistKey = normalizedArtist(track.artist)
        guard !titleKey.isEmpty || !artistKey.isEmpty else { return nil }

        let version = versionCategory(for: title)
        let groupKey = "\(artistKey)|\(titleKey)|\(version.rawValue)"

        return Candidate(
            track: track,
            artistDisplay: displayArtist(for: track),
            titleDisplay: displayTitle(for: track),
            version: version,
            groupKey: groupKey
        )
    }

    private static func displayArtist(for track: Track) -> String {
        let artist = track.artist.trimmingCharacters(in: .whitespacesAndNewlines)
        return artist.isEmpty ? "Unknown Artist" : artist
    }

    private static func displayTitle(for track: Track) -> String {
        let title = titleSource(for: track).trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? track.fileURL.deletingPathExtension().lastPathComponent : title
    }

    private static func titleSource(for track: Track) -> String {
        let title = track.title.trimmingCharacters(in: .whitespacesAndNewlines)
        if !title.isEmpty {
            return title
        }
        return track.fileURL.deletingPathExtension().lastPathComponent
    }

    /// Compiled once — `String.range(of:options:.regularExpression)` and
    /// `replacingOccurrences(options:.regularExpression)` recompile their
    /// pattern on every call, which dominated the duplicate scan (dozens of
    /// compilations per track across a whole library).
    private static let versionCategoryMatchers: [(VersionCategory, [NSRegularExpression])] = [
        (.quickHit, [#"\bquick\s*hit\b"#, #"\bquickhit\b"#]),
        (.intro, [#"\bintro\b"#]),
        (.extended, [#"\bextended\b"#, #"\bext\b"#]),
        (.clean, [#"\bclean\b"#]),
        (.dirty, [#"\bdirty\b"#, #"\bexplicit\b"#]),
        (.radio, [#"\bradio\b"#]),
        (.instrumental, [#"\binstrumental\b"#]),
        (.acapella, [#"\bacapella\b"#, #"\ba\s*cappella\b"#]),
        (.vip, [#"\bvip\b"#]),
        (.remix, [#"\bremix\b"#]),
        (.edit, [#"\bedit\b"#]),
        (.mix, [#"\bmix\b"#]),
        (.club, [#"\bclub\b"#]),
        (.bootleg, [#"\bbootleg\b"#]),
        (.rework, [#"\brework\b"#]),
        (.outro, [#"\boutro\b"#]),
        (.live, [#"\blive\b"#]),
        (.demo, [#"\bdemo\b"#]),
        (.original, [#"\boriginal\s+mix\b"#, #"\boriginal\b"#, #"\bmain\s+mix\b"#, #"\bmain\b"#])
    ].map { category, patterns in
        (category, patterns.map { try! NSRegularExpression(pattern: $0) })
    }

    private static func versionCategory(for title: String) -> VersionCategory {
        let normalizedTitle = normalized(title)
        let fullRange = NSRange(normalizedTitle.startIndex..., in: normalizedTitle)

        for (category, matchers) in versionCategoryMatchers {
            if matchers.contains(where: { $0.firstMatch(in: normalizedTitle, options: [], range: fullRange) != nil }) {
                return category
            }
        }

        return titleContainsVersionHint(normalizedTitle) ? .other : .original
    }

    private static func titleContainsVersionHint(_ normalizedTitle: String) -> Bool {
        normalizedTitle.contains(" mix ")
            || normalizedTitle.hasSuffix(" mix")
            || normalizedTitle.contains(" version ")
            || normalizedTitle.hasSuffix(" version")
    }

    private static let featParenRegex = try! NSRegularExpression(pattern: #"\((feat|featuring|ft)\.?[^)]*\)"#)
    private static let featBracketRegex = try! NSRegularExpression(pattern: #"\[(feat|featuring|ft)\.?[^\]]*\]"#)
    private static let featTrailingRegex = try! NSRegularExpression(pattern: #"\b(feat|featuring|ft)\.?\s+[a-z0-9\s&,'\-]+$"#)
    private static let versionWordsRegex = try! NSRegularExpression(
        pattern: #"\b(quick\s*hit|quickhit|a\s*cappella|acapella|instrumental|extended|ext|bootleg|rework|remix|mixshow|original|version|official|intro|outro|radio|clean|dirty|explicit|main|vip|live|demo|edit|mix|club)\b"#
    )
    private static let featWordRegex = try! NSRegularExpression(pattern: #"\b(feat|featuring|ft)\.?\b"#)
    private static let artistJoinerRegex = try! NSRegularExpression(pattern: #"\b(with|w|x|presents)\b"#)
    private static let nonAlphanumericRegex = try! NSRegularExpression(pattern: #"[^a-z0-9\s]"#)
    private static let whitespaceRunRegex = try! NSRegularExpression(pattern: #"\s+"#)

    private static func replacingMatches(of regex: NSRegularExpression, in value: String, with replacement: String) -> String {
        regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: NSRange(value.startIndex..., in: value),
            withTemplate: replacement
        )
    }

    private static func normalizedTitle(_ value: String) -> String {
        var result = normalized(value)
        result = replacingMatches(of: featParenRegex, in: result, with: " ")
        result = replacingMatches(of: featBracketRegex, in: result, with: " ")
        result = replacingMatches(of: featTrailingRegex, in: result, with: " ")
        result = replacingMatches(of: versionWordsRegex, in: result, with: " ")
        result = replacingMatches(of: whitespaceRunRegex, in: result, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizedArtist(_ value: String) -> String {
        var result = normalized(value)
        result = replacingMatches(of: featWordRegex, in: result, with: " ")
        result = replacingMatches(of: artistJoinerRegex, in: result, with: " ")
        result = replacingMatches(of: whitespaceRunRegex, in: result, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalized(_ value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current)
            .lowercased()
        var result = replacingMatches(of: nonAlphanumericRegex, in: folded, with: " ")
        result = replacingMatches(of: whitespaceRunRegex, in: result, with: " ")
        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}