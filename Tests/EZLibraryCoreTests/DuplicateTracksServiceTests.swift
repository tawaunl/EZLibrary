import Foundation
import Testing
@testable import EZLibraryCore

@Test func duplicateFinderSeparatesDJVersionsIntoDifferentGroups() {
    let tracks: [Track] = [
        Track(
            seratoStoredPath: "Music/Artist - Anthem.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem.mp3"),
            title: "Anthem",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem (Copy).mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem (Copy).mp3"),
            title: "Anthem",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem (Clean).mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem (Clean).mp3"),
            title: "Anthem (Clean)",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem Clean Copy.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem Clean Copy.mp3"),
            title: "Anthem Clean",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem (Extended Mix).mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem (Extended Mix).mp3"),
            title: "Anthem (Extended Mix)",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem Extended Copy.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem Extended Copy.mp3"),
            title: "Anthem Extended",
            artist: "Artist"
        )
    ]

    let groups = DuplicateTracksService.duplicateGroups(in: tracks)

    #expect(groups.count == 3)
    #expect(groups.contains { $0.versionLabel == "Original" && $0.trackCount == 2 })
    #expect(groups.contains { $0.versionLabel == "Clean" && $0.trackCount == 2 })
    #expect(groups.contains { $0.versionLabel == "Extended" && $0.trackCount == 2 })
}

@Test func duplicateFinderKeepsQuickHitSeparateFromOriginal() {
    let tracks: [Track] = [
        Track(
            seratoStoredPath: "Music/Artist - Anthem.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem.mp3"),
            title: "Anthem",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem (Alt Copy).mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem (Alt Copy).mp3"),
            title: "Anthem",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem Quick Hit.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem Quick Hit.mp3"),
            title: "Anthem (Quick Hit)",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem Quick Hit Copy.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem Quick Hit Copy.mp3"),
            title: "Anthem QuickHit",
            artist: "Artist"
        )
    ]

    let groups = DuplicateTracksService.duplicateGroups(in: tracks)

    #expect(groups.count == 2)
    #expect(groups.contains { $0.versionLabel == "Original" && $0.trackCount == 2 })
    #expect(groups.contains { $0.versionLabel == "Quick Hit" && $0.trackCount == 2 })
}

@Test func duplicateSummaryCountsRedundantTracks() {
    let tracks: [Track] = [
        Track(
            seratoStoredPath: "Music/Artist - Anthem.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem.mp3"),
            title: "Anthem",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem Copy.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem Copy.mp3"),
            title: "Anthem",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem (Clean).mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem (Clean).mp3"),
            title: "Anthem (Clean)",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem (Clean) Copy.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem (Clean) Copy.mp3"),
            title: "Anthem Clean",
            artist: "Artist"
        )
    ]

    let summary = DuplicateTracksService.summary(for: tracks)

    #expect(summary.totalTracks == 4)
    #expect(summary.duplicateGroupCount == 2)
    #expect(summary.redundantTrackCount == 2)
    #expect(summary.versionSeparatedGroupCount == 1)
}

@Test func duplicateGroupReportsFilenameDifferences() {
    let differentNames: [Track] = [
        Track(seratoStoredPath: "a", fileURL: URL(fileURLWithPath: "/tmp/Anthem.mp3"), title: "Anthem", artist: "Artist"),
        Track(seratoStoredPath: "b", fileURL: URL(fileURLWithPath: "/tmp/Anthem-2.mp3"), title: "Anthem", artist: "Artist")
    ]
    let diffGroups = DuplicateTracksService.duplicateGroups(in: differentNames)
    #expect(diffGroups.count == 1)
    #expect(diffGroups[0].hasDifferentFilenames)
    #expect(diffGroups[0].uniqueFilenameCount == 2)

    let sameNames: [Track] = [
        Track(seratoStoredPath: "x", fileURL: URL(fileURLWithPath: "/vol1/Track.mp3"), title: "Song", artist: "Band"),
        Track(seratoStoredPath: "y", fileURL: URL(fileURLWithPath: "/vol2/track.MP3"), title: "Song", artist: "Band")
    ]
    let sameGroups = DuplicateTracksService.duplicateGroups(in: sameNames)
    #expect(sameGroups.count == 1)
    #expect(!sameGroups[0].hasDifferentFilenames)
    #expect(sameGroups[0].uniqueFilenameCount == 1)
}

@Test func bestTrackPrefersMostCompleteTags() {
    let full = Track(
        seratoStoredPath: "full",
        fileURL: URL(fileURLWithPath: "/tmp/full.mp3"),
        title: "Song", artist: "Artist", album: "Album", genre: "House",
        comment: "note", year: 2020, bpm: 124, key: "8A", trackNumber: 3,
        dateAdded: Date(timeIntervalSince1970: 100 * 86400)
    )
    let sparse = Track(
        seratoStoredPath: "sparse",
        fileURL: URL(fileURLWithPath: "/tmp/sparse.mp3"),
        title: "Song", artist: "Artist",
        dateAdded: Date(timeIntervalSince1970: 1 * 86400)
    )

    #expect(DuplicateTracksService.completenessScore(for: full) > DuplicateTracksService.completenessScore(for: sparse))
    #expect(DuplicateTracksService.bestTrack(in: [sparse, full])?.seratoStoredPath == "full")
    #expect(DuplicateTracksService.redundantTracks(in: [sparse, full]).map(\.seratoStoredPath) == ["sparse"])
}

@Test func bestTrackBreaksTiesByOldestDateAdded() {
    let newer = Track(
        seratoStoredPath: "newer",
        fileURL: URL(fileURLWithPath: "/tmp/newer.mp3"),
        title: "Tune", artist: "X", album: "Y",
        dateAdded: Date(timeIntervalSince1970: 50 * 86400)
    )
    let older = Track(
        seratoStoredPath: "older",
        fileURL: URL(fileURLWithPath: "/tmp/older.mp3"),
        title: "Tune", artist: "X", album: "Y",
        dateAdded: Date(timeIntervalSince1970: 10 * 86400)
    )
    let undated = Track(
        seratoStoredPath: "undated",
        fileURL: URL(fileURLWithPath: "/tmp/undated.mp3"),
        title: "Tune", artist: "X", album: "Y",
        dateAdded: nil
    )

    #expect(DuplicateTracksService.bestTrack(in: [newer, older])?.seratoStoredPath == "older")
    #expect(DuplicateTracksService.bestTrack(in: [undated, newer])?.seratoStoredPath == "newer")
}