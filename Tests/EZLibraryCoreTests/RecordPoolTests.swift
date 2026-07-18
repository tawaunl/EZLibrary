import Testing
import Foundation
@testable import EZLibraryCore

// MARK: - BPM Supreme parsing (pure, offline)

@Test func bpmSupremeParsesTokenFromNestedLoginJSON() {
    let json = """
    { "data": { "session": { "access_token": "abc123", "user": { "id": 7 } } } }
    """.data(using: .utf8)!
    #expect(BPMSupremeProvider.parseToken(fromLoginJSON: json) == "abc123")
}

@Test func bpmSupremeParsesSearchResults() {
    let json = """
    { "data": [
        { "id": 101, "title": "Feel So Close", "artists": [{ "name": "Calvin Harris" }], "version": "Extended", "slug": "feel-so-close" },
        { "id": 102, "title": "Summer", "artist": "Calvin Harris", "url": "https://app.bpmsupreme.com/d/song/summer" }
    ] }
    """.data(using: .utf8)!

    let results = BPMSupremeProvider.parseResults(fromSearchJSON: json)
    #expect(results.count == 2)
    #expect(results.first?.title == "Feel So Close")
    #expect(results.first?.artist == "Calvin Harris")
    #expect(results.first?.versionLabel == "Extended")
    #expect(results.first?.url.absoluteString == "https://app.bpmsupreme.com/d/song/feel-so-close")
    #expect(results.last?.url.absoluteString == "https://app.bpmsupreme.com/d/song/summer")
}

@Test func bpmSupremeReturnsEmptyForUnexpectedJSON() {
    let json = "{ \"error\": \"nope\" }".data(using: .utf8)!
    #expect(BPMSupremeProvider.parseResults(fromSearchJSON: json).isEmpty)
}

// MARK: - DJcity parsing (pure, offline)

@Test func djCityParsesTrackAnchorsFromHTML() {
    let html = """
    <html><body>
      <div class="results">
        <a href="/us/store/song/12345/feel-so-close">Feel So Close &amp; More</a>
        <a href="https://www.djcity.com/us/store/song/67890/summer">Summer</a>
        <a href="/us/help">Help</a>
      </div>
    </body></html>
    """

    let results = DJCityProvider.parseResults(fromHTML: html, baseURL: "https://www.djcity.com")
    #expect(results.count == 2)
    #expect(results.first?.title == "Feel So Close & More")
    #expect(results.first?.url.absoluteString == "https://www.djcity.com/us/store/song/12345/feel-so-close")
    #expect(results.last?.url.absoluteString == "https://www.djcity.com/us/store/song/67890/summer")
}

// MARK: - Match confirmation

@Test func recordPoolMatchConfirmsByTitleAndArtist() {
    let results = [
        RecordPoolResult(pool: .bpmSupreme, title: "Feel So Close", artist: "Calvin Harris", url: URL(string: "https://x/1")!),
        RecordPoolResult(pool: .bpmSupreme, title: "Totally Different Song", artist: "Someone", url: URL(string: "https://x/2")!),
    ]
    let confirmed = RecordPoolMatch.confirmed(results, title: "Feel So Close", artist: "Calvin Harris", limit: 6)
    #expect(confirmed.count == 1)
    #expect(confirmed.first?.title == "Feel So Close")
}

@Test func recordPoolMatchRejectsArtistMismatch() {
    let results = [
        RecordPoolResult(pool: .djCity, title: "Closer", artist: "Ne-Yo", url: URL(string: "https://x/1")!),
    ]
    let confirmed = RecordPoolMatch.confirmed(results, title: "Closer", artist: "The Chainsmokers", limit: 6)
    #expect(confirmed.isEmpty)
}
