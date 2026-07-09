import Testing
@testable import SeratoToolsCore

@Test func searchableTermStripsTrailingDescriptors() {
    #expect(OnlineTrackMetadataLookupService.searchableTerm("Song Name (Intro)") == "Song Name")
    #expect(OnlineTrackMetadataLookupService.searchableTerm("Song Name (X) (Live)") == "Song Name")
    #expect(OnlineTrackMetadataLookupService.searchableTerm("Song Name [Intro]") == "Song Name")
    #expect(OnlineTrackMetadataLookupService.searchableTerm("Song Name") == "Song Name")
    #expect(OnlineTrackMetadataLookupService.searchableTerm("  Song Name (etc.)  ") == "Song Name")
}
