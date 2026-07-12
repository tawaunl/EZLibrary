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
    #expect(result.matchedEntries.first?.confidence == .high)
    #expect(result.matchedEntries.first?.reason == .exactTitleAndArtist)
    #expect(result.planItems.count == 1)
    #expect(result.planItems.first?.entry.title == "Turn Off The Lights")
}

@Test func playlistMatchReturnsAllLibraryVersionsForMatchedSong() {
    let libraryTracks: [Track] = [
        Track(
            seratoStoredPath: "Music/Artist - Anthem (Extended Mix).mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem (Extended Mix).mp3"),
            title: "Anthem (Extended Mix)",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem (Intro).mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem (Intro).mp3"),
            title: "Anthem (Intro)",
            artist: "Artist"
        ),
        Track(
            seratoStoredPath: "Music/Artist - Anthem (Instrumental).mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem (Instrumental).mp3"),
            title: "Anthem (Instrumental)",
            artist: "Artist"
        )
    ]

    let entries: [PlaylistMatchService.PlaylistEntry] = [
        .init(title: "Anthem", artist: "Artist", sourceLine: "Artist - Anthem")
    ]

    let result = PlaylistMatchService.match(entries: entries, libraryTracks: libraryTracks)

    #expect(result.matchedEntries.count == 1)
    #expect(result.matchedEntries[0].versions.count == 3)
    #expect(result.matchedTracks.count == 1)
}

@Test func playlistMatchHandlesExtendedAndFeatureMarkersIncludingFtDot() {
    let libraryTracks: [Track] = [
        Track(
            seratoStoredPath: "Music/Artist - Anthem Extended.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Artist - Anthem Extended.mp3"),
            title: "Anthem Extended",
            artist: "Artist ft. Guest"
        )
    ]

    let entries: [PlaylistMatchService.PlaylistEntry] = [
        .init(title: "Anthem (Extended Mix)", artist: "Artist featuring Guest", sourceLine: "Artist featuring Guest - Anthem (Extended Mix)"),
        .init(title: "Anthem ft. Guest", artist: "Artist", sourceLine: "Artist - Anthem ft. Guest")
    ]

    let result = PlaylistMatchService.match(entries: entries, libraryTracks: libraryTracks)

    #expect(result.matchedEntries.count == 2)
    #expect(result.planItems.isEmpty)
}

@Test func playlistMatchHandlesRemixAndVersionLabels() {
    let libraryTracks: [Track] = [
        Track(
            seratoStoredPath: "Music/Producer - Banger.mp3",
            fileURL: URL(fileURLWithPath: "/tmp/Producer - Banger.mp3"),
            title: "Banger",
            artist: "Producer"
        )
    ]

    let entries: [PlaylistMatchService.PlaylistEntry] = [
        .init(title: "Banger (VIP Mix)", artist: "Producer", sourceLine: "Producer - Banger (VIP Mix)"),
        .init(title: "Banger - Club Mix", artist: "Producer", sourceLine: "Producer - Banger - Club Mix"),
        .init(title: "Banger (Bootleg Rework)", artist: "Producer", sourceLine: "Producer - Banger (Bootleg Rework)")
    ]

    let result = PlaylistMatchService.match(entries: entries, libraryTracks: libraryTracks)

    #expect(result.matchedEntries.count == 3)
    #expect(result.planItems.isEmpty)
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

@Test func playlistMatchPlanRoundTripSaveLoad() throws {
    let tempDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("playlistmatch-plan-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDirectory) }

    let fileURL = tempDirectory.appendingPathComponent("plan.playlistmatch-plan.json")
    let source: [PlaylistMatchService.PlanItem] = [
        .init(entry: .init(title: "Track One", artist: "Artist One", sourceLine: "Artist One - Track One")),
        .init(entry: .init(title: "Track Two", artist: "Artist Two", sourceLine: "Artist Two - Track Two"))
    ]

    try PlaylistMatchService.savePlan(source, to: fileURL)
    let loaded = try PlaylistMatchService.loadPlan(from: fileURL)

    #expect(loaded.count == 2)
    #expect(loaded[0].entry.title == "Track One")
    #expect(loaded[1].entry.artist == "Artist Two")
}

@Test func spotifyEmbedNextDataParsesTrackListAndName() {
    // Mirrors the shape of Spotify's embed __NEXT_DATA__ payload:
    // props.pageProps.state.data.entity.{name,trackList[{title,subtitle}]}.
    let html = """
    <html><body>
    <script id="__NEXT_DATA__" type="application/json">
    {"props":{"pageProps":{"state":{"data":{"entity":{
      "name":"My Test Playlist",
      "trackList":[
        {"uri":"spotify:track:1","title":"First Song","subtitle":"Artist One"},
        {"uri":"spotify:track:2","title":"Second Song","subtitle":"Artist Two, Guest"},
        {"uri":"spotify:track:3","title":"","subtitle":"No Title"},
        {"uri":"spotify:track:1","title":"First Song","subtitle":"Artist One"}
      ]
    }}}}}}
    </script>
    </body></html>
    """

    let parsed = PlaylistMatchService.parseSpotifyEmbedNextData(html)

    #expect(parsed.name == "My Test Playlist")
    // Empty-title row is skipped and the duplicate is de-duped.
    #expect(parsed.entries.count == 2)
    #expect(parsed.entries[0].title == "First Song")
    #expect(parsed.entries[0].artist == "Artist One")
    #expect(parsed.entries[1].title == "Second Song")
    #expect(parsed.entries[1].artist == "Artist Two, Guest")
}

@Test func spotifyEmbedNextDataReturnsEmptyWhenNoTrackList() {
    let html = "<html><body><script id=\"__NEXT_DATA__\" type=\"application/json\">{\"props\":{}}</script></body></html>"
    let parsed = PlaylistMatchService.parseSpotifyEmbedNextData(html)
    #expect(parsed.entries.isEmpty)
    #expect(parsed.name == nil)
}
