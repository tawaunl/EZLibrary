import Foundation
import Testing
@testable import SeratoToolsCore

@Test func playlistMatchParsesCSVRows() {
    let input = """
    title,artist
    Lights Up,Kaytranada
    Int'l Players Anthem,UGK
    """

    let entries = PlaylistMatchService.parseEntries(from: input)

    #expect(entries.count == 2)
    #expect(entries[0].title == "Lights Up")
    #expect(entries[0].artist == "Kaytranada")
    #expect(entries[1].title == "Int'l Players Anthem")
    #expect(entries[1].artist == "UGK")
}

@Test func playlistMatchFindsExactAndPlansMisses() {
    let libraryTracks: [Track] = [
        Track(
            seratoStoredPath: "Music/Drake - Headlines.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Drake - Headlines.mp3"),
            title: "Headlines",
            artist: "Drake"
        ),
        Track(
            seratoStoredPath: "Music/Fred again.. - Delilah.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Fred again.. - Delilah.mp3"),
            title: "Delilah",
            artist: "Fred again.."
        )
    ]

    let entries: [PlaylistMatchService.PlaylistEntry] = [
        .init(title: "Headlines", artist: "Drake", sourceLine: "Drake - Headlines"),
        .init(title: "Turn Off The Lights", artist: "Future", sourceLine: "Future - Turn Off The Lights")
    ]

    let result = PlaylistMatchService.match(entries: entries, libraryTracks: libraryTracks)

    #expect(result.matchedTracks.count == 1)
    #expect(result.matchedTracks.first?.title == "Headlines")
    #expect(result.planItems.count == 1)
    #expect(result.planItems.first?.entry.title == "Turn Off The Lights")
}

@Test func playlistMatchExtractsCanonicalSpotifyPlaylistURLFromCommonFormats() {
    let direct = PlaylistMatchService.spotifyPlaylistURL(from: "https://open.spotify.com/playlist/37i9dQZF1DX4SBhb3fqCJd?si=abc123")
    let embed = PlaylistMatchService.spotifyPlaylistURL(from: "https://open.spotify.com/embed/playlist/37i9dQZF1DX4SBhb3fqCJd")
    let legacy = PlaylistMatchService.spotifyPlaylistURL(from: "https://play.spotify.com/playlist/37i9dQZF1DX4SBhb3fqCJd")
    let userPath = PlaylistMatchService.spotifyPlaylistURL(from: "https://open.spotify.com/user/someuser/playlist/37i9dQZF1DX4SBhb3fqCJd")
    let uri = PlaylistMatchService.spotifyPlaylistURL(from: "spotify:playlist:37i9dQZF1DX4SBhb3fqCJd")

    let expected = "https://open.spotify.com/playlist/37i9dQZF1DX4SBhb3fqCJd"
    #expect(direct?.absoluteString == expected)
    #expect(embed?.absoluteString == expected)
    #expect(legacy?.absoluteString == expected)
    #expect(userPath?.absoluteString == expected)
    #expect(uri?.absoluteString == expected)
}

@Test func playlistMatchExtractsSpotifyURLFromWrappedPastedText() {
    let wrapped = "Paste this playlist: <https://open.spotify.com/playlist/37i9dQZF1DX4SBhb3fqCJd>, thanks."
    let extracted = PlaylistMatchService.spotifyPlaylistURL(from: wrapped)
    #expect(extracted?.absoluteString == "https://open.spotify.com/playlist/37i9dQZF1DX4SBhb3fqCJd")
}
