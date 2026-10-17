import Testing
@testable import EZLibraryCore

@Test func poolTitlesLoseTheirFilenameSuffix() {
    let cases: [(String, String, String)] = [
        ("4Get The Girl - Main - Route 94 - 122 - 10A", "Route 94", "4Get The Girl"),
        ("Time - Edit - Main - Hot Since 82, Kuuda - 124 - 10A", "Hot Since 82, Kuuda", "Time - Edit"),
        ("Phreaky - Extended - Mike Dunn, Sorley - 126 - 4B", "Mike Dunn, Sorley", "Phreaky (Extended)"),
        ("Verano En NY - Main - Toman, Tomàn - 126 - 10B", "Toman, Tomàn", "Verano En NY"),
        ("C-Line Woman - Main - DJ Dan, Taurus (US) - 126 - 4B", "DJ Dan, Taurus (US)", "C-Line Woman")
    ]
    for (title, artist, expected) in cases {
        #expect(PoolTitleCleaner.clean(title: title, artist: artist) == expected)
    }
}

@Test func aReformattedArtistCreditStillCleansViaTheVersionLabel() {
    #expect(PoolTitleCleaner.clean(title: "Song - Main - A & B - 120 - 8A", artist: "A, B") == "Song")
}

@Test func normalTitlesAreLeftAlone() {
    for title in ["Latch", "Song - Remix", "Track - Main", "Hello - 120 Mix", "Intro - Dirty"] {
        #expect(PoolTitleCleaner.clean(title: title, artist: "X") == title)
    }
}
