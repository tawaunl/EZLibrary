// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Testing
import Foundation
@testable import EZLibraryCore

/// Covers the pure DJ Pool Records listing parser — the network fetch wraps it
/// but the extraction logic is tested here against real post markup.
struct DJPoolRecordsParsingTests {

    private static let sampleHTML = """
    <p><img loading="lazy" src="https://djpoolrecords.com/wp-content/cover-230x230.jpg" alt="" /></p>
    <p><strong>50 Cent &#8211; Candy Shop (Shvdz Edit) (10.31 MB)</strong><br />
    <strong>Alice Deejay X Mave &#8211; Better Off Alone (Dj Allan 2026 Edit) 130 (7.64 MB)</strong><br />
    <strong>A-Ha &#8211; Take On Me (Jestei Pool Redrum) 85 Bpm 170 (9.00 MB)</strong></p>
    <p><strong>Cher &#8211; Take Me Home (Throwback Brothers Remix) 120 (9.79 MB)</strong></p>
    """

    @Test func parsesArtistTitleAndBPMFromRealMarkup() {
        let entries = OnlineTrackMetadataLookupService.parseDJPoolRecordsListing(html: Self.sampleHTML)

        // The image credit line carries no track, so it is skipped.
        #expect(entries.count == 4)

        #expect(entries[0] == .init(artist: "50 Cent", title: "Candy Shop (Shvdz Edit)", bpm: nil))
        #expect(entries[1] == .init(
            artist: "Alice Deejay X Mave", title: "Better Off Alone (Dj Allan 2026 Edit)", bpm: 130))
        // `85 Bpm 170` -> the leading value is the track BPM.
        #expect(entries[2] == .init(artist: "A-Ha", title: "Take On Me (Jestei Pool Redrum)", bpm: 85))
        #expect(entries[3] == .init(artist: "Cher", title: "Take Me Home (Throwback Brothers Remix)", bpm: 120))
    }

    @Test func skipsLinesThatAreNotTrackEntries() {
        let entries = OnlineTrackMetadataLookupService.parseDJPoolRecordsListing(
            html: "<p>Record Search</p><p><strong>Latest Releases</strong></p>")
        #expect(entries.isEmpty)
    }

    @Test func decodesCommonHTMLEntities() {
        #expect(OnlineTrackMetadataLookupService.decodeHTMLEntities("Sam &#038; Dave &amp; Co &#8211; Hold On")
            == "Sam & Dave & Co – Hold On")
    }

    @Test func matchesAcrossReorderedMultiArtistCreditsAndEditDescriptors() {
        let entry = OnlineTrackMetadataLookupService.DJPoolListingEntry(
            artist: "Disco Lines, Tinashe", title: "No Broke Boys (Intro Dirty)", bpm: nil)
        let wantedTitle = OnlineTrackMetadataLookupService.djPoolNormalize("No Broke Boys")
        let wantedArtist = OnlineTrackMetadataLookupService.djPoolNormalize("Tinashe & Disco Lines")

        #expect(OnlineTrackMetadataLookupService.djPoolEntryMatches(
            entry, title: wantedTitle, artist: wantedArtist))
    }

    @Test func rejectsAWrongTitleEvenWhenTheArtistMatches() {
        let entry = OnlineTrackMetadataLookupService.DJPoolListingEntry(
            artist: "50 Cent", title: "In Da Club (Intro Clean)", bpm: nil)
        let wantedTitle = OnlineTrackMetadataLookupService.djPoolNormalize("Candy Shop")
        let wantedArtist = OnlineTrackMetadataLookupService.djPoolNormalize("50 Cent")

        #expect(!OnlineTrackMetadataLookupService.djPoolEntryMatches(
            entry, title: wantedTitle, artist: wantedArtist))
    }
}
