import Testing
@testable import EZLibraryCore

@Test func poolNamesAreRemovedFromAlbums() {
    for name in ["ID By Rivoli", "BPM Supreme", "DJcity", "DJ City", "dj city", "Beat Junkies", "MyMP3Pool", "mymp3pool"] {
        #expect(PoolPlaceholderFilter.cleanedTag(name) == nil, "\(name) should be removed")
    }
}

@Test func realAlbumsSurvive() {
    for name in ["Obsessions", "Beat Junkies Vol. 1", "Artizan", "City Lights"] {
        #expect(PoolPlaceholderFilter.cleanedTag(name) == name)
    }
}

@Test func trailingPoolTagsLeaveTheTitle() {
    #expect(PoolPlaceholderFilter.strippingTrailingPoolTag(from: "Latch (DJcity)") == "Latch")
    #expect(PoolPlaceholderFilter.strippingTrailingPoolTag(from: "Latch [BPM Supreme]") == "Latch")
    #expect(PoolPlaceholderFilter.strippingTrailingPoolTag(from: "Latch - MyMP3Pool") == "Latch")
    #expect(PoolPlaceholderFilter.strippingTrailingPoolTag(from: "Latch (Dirty)") == "Latch (Dirty)")
}

@Test func poolPromoTextIsRemovedFromComments() {
    #expect(PoolPlaceholderFilter.cleanedComment("BPM Supreme") == nil)
    #expect(PoolPlaceholderFilter.cleanedComment("Downloaded from DJcity") == nil)
    #expect(PoolPlaceholderFilter.cleanedComment("www.mymp3pool.com") == nil)
    #expect(PoolPlaceholderFilter.cleanedComment("Dirty | DJcity") == "Dirty")
    #expect(PoolPlaceholderFilter.cleanedComment("Great opener") == "Great opener")
    #expect(PoolPlaceholderFilter.cleanedComment("Loved at Beat Junkies night") == "Loved at Beat Junkies night")
}
