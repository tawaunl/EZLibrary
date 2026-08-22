#if DEBUG
import EZLibrarySnapshotKit

extension SnapshotLibrary {
    static let preview: SnapshotLibrary = {
        let tracks: [SnapshotTrack] = [
            SnapshotTrack(storedPath: "/Music/Disclosure - You & Me.mp3",
                          title: "You & Me", artist: "Disclosure", album: "Settle",
                          genre: "Electronic", duration: 238, bpm: 123, key: "4A", playCount: 12),
            SnapshotTrack(storedPath: "/Music/Peggy Gou - Nanana.mp3",
                          title: "(It Goes Like) Nanana", artist: "Peggy Gou",
                          album: "I Hear You", genre: "House", bpm: 128, key: "7B"),
            SnapshotTrack(storedPath: "/Music/Fred Again - Marea.mp3",
                          title: "Marea (We've Lost Dancing)", artist: "Fred Again.. & The Blessed Madonna",
                          album: "Actual Life 2", genre: "House", duration: 315,
                          bitrate: "320 kbps", bpm: 130, key: "6A", playCount: 44),
            SnapshotTrack(storedPath: "/Music/Bonobo - Kiara.mp3",
                          title: "Kiara", artist: "Bonobo", album: "Black Sands",
                          genre: "Electronic", duration: 406, bpm: 90, key: "9A"),
            SnapshotTrack(storedPath: "/Music/Four Tet - Baby.mp3",
                          title: "Baby", artist: "Four Tet", album: "There Is Love In You",
                          genre: "Electronic", bpm: 138, key: "2A"),
            SnapshotTrack(storedPath: "/Music/Kaytranada - 10pct.mp3",
                          title: "10%", artist: "Kaytranada ft. Kali Uchis",
                          album: "99.9%", genre: "House", duration: 185, bpm: 118, key: "11B",
                          playCount: 7),
            SnapshotTrack(storedPath: "/Music/Caribou - Cant Do Without You.mp3",
                          title: "Can't Do Without You", artist: "Caribou",
                          album: "Our Love", genre: "Electronic", duration: 202, bpm: 123, key: "5A"),
        ]

        let crates: [SnapshotCrate] = [
            SnapshotCrate(
                pathComponents: ["House"],
                trackPaths: [tracks[1].storedPath, tracks[2].storedPath, tracks[5].storedPath]
            ),
            SnapshotCrate(
                pathComponents: ["Electronic"],
                trackPaths: [tracks[0].storedPath, tracks[3].storedPath, tracks[4].storedPath, tracks[6].storedPath]
            ),
            SnapshotCrate(
                pathComponents: ["Electronic", "Downtempo"],
                trackPaths: [tracks[3].storedPath, tracks[6].storedPath]
            ),
        ]

        let snapshot = LibrarySnapshot(
            libraryFingerprint: "preview",
            tracks: tracks,
            crates: crates
        )
        return SnapshotLibrary(snapshot: snapshot)
    }()
}
#endif
