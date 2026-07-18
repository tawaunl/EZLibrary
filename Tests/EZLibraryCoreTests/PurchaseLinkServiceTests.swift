import Foundation
import Testing
@testable import EZLibraryCore

@Test func purchaseLinkSearchQueryJoinsArtistAndTitle() {
    #expect(PurchaseLinkService.searchQuery(title: "Headlines", artist: "Drake") == "Drake Headlines")
    #expect(PurchaseLinkService.searchQuery(title: "  Delilah  ", artist: "") == "Delilah")
    #expect(PurchaseLinkService.searchQuery(title: "", artist: "") == "")
}

@Test func purchaseLinkSlugifyMatchesBeatportStyle() {
    #expect(PurchaseLinkService.slugify("Losing It") == "losing-it")
    #expect(PurchaseLinkService.slugify("World Hold On (feat. Steve Edwards)") == "world-hold-on-feat-steve-edwards")
    #expect(PurchaseLinkService.slugify("  Déjà Vu!! ") == "deja-vu")
}

@Test func purchaseLinkTitleAndArtistMatching() {
    #expect(PurchaseLinkService.titleMatches("Losing It", "Losing It"))
    #expect(PurchaseLinkService.titleMatches("Losing It", "Losing It (Extended Mix)"))
    #expect(!PurchaseLinkService.titleMatches("Losing It", "Take It Off"))

    // Empty entry artist means "don't constrain by artist".
    #expect(PurchaseLinkService.artistMatches(entryArtist: "", candidate: "FISHER (OZ)"))
    #expect(PurchaseLinkService.artistMatches(entryArtist: "Fisher", candidate: "FISHER (OZ)"))
    #expect(!PurchaseLinkService.artistMatches(entryArtist: "Drake", candidate: "FISHER (OZ)"))
}

@Test func purchaseLinkArtistMatchingIsOrderIndependent() {
    // Reordered multi-artist credit (the No Broke Boys bug).
    #expect(PurchaseLinkService.artistMatches(entryArtist: "Disco Lines & Tinashe", candidate: "Tinashe, Disco Lines"))
    // Remix credit that adds an extra artist.
    #expect(PurchaseLinkService.artistMatches(entryArtist: "Disco Lines & Tinashe", candidate: "Tinashe, AVELLO, Disco Lines"))
    // Subset either way.
    #expect(PurchaseLinkService.artistMatches(entryArtist: "Tinashe", candidate: "Tinashe, Disco Lines"))
    #expect(!PurchaseLinkService.artistMatches(entryArtist: "Drake", candidate: "Tinashe, Disco Lines"))
}

@Test func purchaseLinkArtistNameListSplitsCredits() {
    #expect(PurchaseLinkService.artistNameList("Disco Lines & Tinashe") == ["Disco Lines", "Tinashe"])
    #expect(PurchaseLinkService.artistNameList("Tinashe, Disco Lines") == ["Tinashe", "Disco Lines"])
    #expect(PurchaseLinkService.artistNameList("Calvin Harris feat. Example") == ["Calvin Harris", "Example"])
    #expect(PurchaseLinkService.artistNameList("Fisher") == ["Fisher"])
}

@Test func purchaseLinkBeatportMatchesReorderedMultiArtistCredit() {
    let html = """
    <script id="__NEXT_DATA__" type="application/json">
    {"tracks":{"data":[
    {"track_id":100,"track_name":"No Broke Boys","mix_name":"Extended","artists":[{"artist_name":"Tinashe"},{"artist_name":"Disco Lines"}],"price":{"display":"$2.99"}},
    {"track_id":101,"track_name":"No Broke Boys","mix_name":"Original Mix","artists":[{"artist_name":"Tinashe"},{"artist_name":"Disco Lines"}],"price":{"display":"$1.99"}}
    ]}}
    </script>
    """
    let tracks = PurchaseLinkService.parseBeatportTracks(fromHTML: html)
    let links = PurchaseLinkService.beatportLinks(matchingTitle: "No Broke Boys", artist: "Disco Lines & Tinashe", in: tracks)

    #expect(links.count == 2)
    #expect(Set(links.map { $0.versionLabel }) == ["Extended", "Original Mix"])
}

private let beatportSampleHTML = """
<html><head>
<script id="__NEXT_DATA__" type="application/json">
{"props":{"pageProps":{"dehydratedState":{"queries":[{"state":{"data":{"tracks":{"data":[
{"track_id":10766349,"track_name":"Losing It","mix_name":"Extended","artists":[{"artist_id":628537,"artist_name":"FISHER (OZ)"}],"price":{"code":"USD","symbol":"$","value":2.49,"display":"$2.49"}},
{"track_id":17716164,"track_name":"Take It Off","mix_name":"Extended Mix","artists":[{"artist_id":1,"artist_name":"Aatig"},{"artist_id":628537,"artist_name":"FISHER (OZ)"}],"price":{"display":"$2.49"}}
]}}}}]}}}}
</script>
</head><body></body></html>
"""

@Test func purchaseLinkParsesBeatportNextData() {
    let tracks = PurchaseLinkService.parseBeatportTracks(fromHTML: beatportSampleHTML)
    #expect(tracks.count == 2)

    let first = tracks[0]
    #expect(first.trackID == 10766349)
    #expect(first.trackName == "Losing It")
    #expect(first.mixName == "Extended")
    #expect(first.artists == ["FISHER (OZ)"])
    #expect(first.priceDisplay == "$2.49")
}

@Test func purchaseLinkBuildsConfirmedBeatportLinkForMatch() throws {
    let tracks = PurchaseLinkService.parseBeatportTracks(fromHTML: beatportSampleHTML)
    let links = PurchaseLinkService.beatportLinks(matchingTitle: "Losing It", artist: "Fisher", in: tracks)

    #expect(links.count == 1)
    let link = try #require(links.first)
    #expect(link.store == .beatport)
    #expect(link.url.absoluteString == "https://www.beatport.com/track/losing-it/10766349")
    #expect(link.title == "Losing It (Extended)")
    #expect(link.subtitle == "FISHER (OZ) · $2.49")
}

@Test func purchaseLinkBeatportReturnsNothingWhenTrackAbsent() {
    let tracks = PurchaseLinkService.parseBeatportTracks(fromHTML: beatportSampleHTML)
    let links = PurchaseLinkService.beatportLinks(matchingTitle: "Nonexistent Song", artist: "Nobody", in: tracks)
    #expect(links.isEmpty)
}

@Test func purchaseLinkBeatportReturnsAllVersionsWhenEntryPinsOne() {
    let html = """
    <script id="__NEXT_DATA__" type="application/json">
    {"tracks":{"data":[
    {"track_id":1,"track_name":"Feel So Close","mix_name":"Original Mix","artists":[{"artist_name":"Calvin Harris"}],"price":{"display":"$1.29"}},
    {"track_id":2,"track_name":"Feel So Close","mix_name":"Radio Edit","artists":[{"artist_name":"Calvin Harris"}],"price":{"display":"$1.29"}},
    {"track_id":3,"track_name":"Feel So Close","mix_name":"Extended Mix","artists":[{"artist_name":"Calvin Harris"}],"price":{"display":"$1.99"}}
    ]}}
    </script>
    """
    let tracks = PurchaseLinkService.parseBeatportTracks(fromHTML: html)
    let links = PurchaseLinkService.beatportLinks(matchingTitle: "Feel So Close - Radio Edit", artist: "Calvin Harris", in: tracks)

    #expect(links.count == 3)
    #expect(Set(links.map { $0.versionLabel }) == ["Original Mix", "Radio Edit", "Extended Mix"])
}

@Test func purchaseLinkParsesEmptyForMissingNextData() {
    #expect(PurchaseLinkService.parseBeatportTracks(fromHTML: "<html><body>no data</body></html>").isEmpty)
}

@Test func purchaseLinkITunesStoreURLForcesStoreApp() {
    let raw = "https://music.apple.com/us/album/losing-it/1408454984?i=1408454985&uo=4"
    let url = try! #require(PurchaseLinkService.iTunesStoreURL(from: raw))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

    #expect(items.contains(URLQueryItem(name: "app", value: "itunes")))
    // Existing params are preserved.
    #expect(items.contains(URLQueryItem(name: "i", value: "1408454985")))
    #expect(items.contains(URLQueryItem(name: "uo", value: "4")))
}

@Test func purchaseLinkITunesStoreURLKeepsExistingAppParam() {
    let raw = "https://music.apple.com/us/album/x/1?i=2&app=music"
    let url = try! #require(PurchaseLinkService.iTunesStoreURL(from: raw))
    let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []

    #expect(items.filter { $0.name == "app" }.count == 1)
    #expect(items.contains(URLQueryItem(name: "app", value: "music")))
}

@Test func purchaseLinkVersionLabelParsesITunesDescriptors() {
    #expect(PurchaseLinkService.versionLabel(fromTrackName: "Losing It") == "Original")
    #expect(PurchaseLinkService.versionLabel(fromTrackName: "Losing It (Radio Edit)") == "Radio Edit")
    #expect(PurchaseLinkService.versionLabel(fromTrackName: "Track [Extended Mix]") == "Extended Mix")
}

@Test func purchaseLinkCoreTitleStripsVersionDescriptors() {
    #expect(PurchaseLinkService.coreTitle("Feel So Close") == "Feel So Close")
    #expect(PurchaseLinkService.coreTitle("Feel So Close (Radio Edit)") == "Feel So Close")
    #expect(PurchaseLinkService.coreTitle("Feel So Close - Radio Edit") == "Feel So Close")
    #expect(PurchaseLinkService.coreTitle("Title (feat. X) [Extended Mix]") == "Title")
}

@Test func purchaseLinkAnyVersionMatchingFindsOtherVersions() {
    // A playlist entry pinned to the Radio Edit should still match the
    // Original and Extended versions of the same song.
    #expect(PurchaseLinkService.titleMatchesAnyVersion("Feel So Close - Radio Edit", "Feel So Close"))
    #expect(PurchaseLinkService.titleMatchesAnyVersion("Feel So Close - Radio Edit", "Feel So Close (Extended Mix)"))
    #expect(!PurchaseLinkService.titleMatchesAnyVersion("Feel So Close - Radio Edit", "Sweet Nothing"))
}

@Test func purchaseLinkBeatportGroupsVersionsAndDedupes() {
    let html = """
    <script id="__NEXT_DATA__" type="application/json">
    {"tracks":{"data":[
    {"track_id":1,"track_name":"Body","mix_name":"Extended Mix","artists":[{"artist_name":"Loud Luxury"}],"price":{"display":"$2.49"}},
    {"track_id":2,"track_name":"Body","mix_name":"Radio Edit","artists":[{"artist_name":"Loud Luxury"}],"price":{"display":"$1.49"}},
    {"track_id":3,"track_name":"Body","mix_name":"Extended Mix","artists":[{"artist_name":"Loud Luxury"}],"price":{"display":"$2.49"}}
    ]}}
    </script>
    """
    let tracks = PurchaseLinkService.parseBeatportTracks(fromHTML: html)
    let links = PurchaseLinkService.beatportLinks(matchingTitle: "Body", artist: "Loud Luxury", in: tracks)

    // The duplicate "Extended Mix" is collapsed; two distinct versions remain.
    #expect(links.count == 2)
    #expect(links.allSatisfy { $0.store == .beatport })
    #expect(Set(links.map { $0.versionLabel }) == ["Extended Mix", "Radio Edit"])
    #expect(links.first(where: { $0.versionLabel == "Radio Edit" })?.priceText == "$1.49")
}
