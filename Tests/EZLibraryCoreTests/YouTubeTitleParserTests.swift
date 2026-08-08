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

struct YouTubeTitleParserTests {

    // MARK: - The reported bug

    /// The case that surfaced this: the channel "E40TV" was being written as
    /// both artist and album, and the whole video title as the title, which
    /// auto-rename then baked into the file name.
    ///
    /// Title and uploader are copied verbatim from what yt-dlp reports for the
    /// video, double space and all.
    @Test func splitsTheArtistOutOfARealUploadTitle() {
        let parsed = YouTubeTitleParser.parse(
            videoTitle: "E-40 & Too $hort - Dump Truck  ft. Travis Porter, Young Chu",
            uploader: "E40TV")

        #expect(parsed.artist == "E-40 & Too $hort")
        #expect(parsed.title == "Dump Truck ft. Travis Porter, Young Chu")
    }

    /// A hyphen inside a name is not a separator — this is why the split only
    /// matches a space-padded dash.
    @Test func hyphenatedArtistNamesSurvive() {
        for name in ["E-40", "Jay-Z", "T-Pain", "Blu-Ray Boys"] {
            let parsed = YouTubeTitleParser.parse(videoTitle: "\(name) - Some Song")
            #expect(parsed.artist == name)
            #expect(parsed.title == "Some Song")
        }
    }

    @Test func handlesEnAndEmDashSeparators() {
        #expect(YouTubeTitleParser.parse(videoTitle: "Artist – Title").artist == "Artist")
        #expect(YouTubeTitleParser.parse(videoTitle: "Artist — Title").title == "Title")
    }

    @Test func splitsOnTheFirstSeparatorOnly() {
        let parsed = YouTubeTitleParser.parse(videoTitle: "Artist - Title - Remix Name")

        #expect(parsed.artist == "Artist")
        #expect(parsed.title == "Title - Remix Name")
    }

    // MARK: - Noise stripping

    @Test func stripsFormatDecorations() {
        let cases = [
            "Artist - Title (Official Video)",
            "Artist - Title [Official Music Video]",
            "Artist - Title (OFFICIAL AUDIO)",
            "Artist - Title [HD]",
            "Artist - Title (Lyrics)",
            "Artist - Title (Official Video) [4K]"
        ]
        for videoTitle in cases {
            let parsed = YouTubeTitleParser.parse(videoTitle: videoTitle)
            #expect(parsed.artist == "Artist", "artist for \(videoTitle)")
            #expect(parsed.title == "Title", "title for \(videoTitle)")
        }
    }

    /// The annotations a DJ actually needs must never be stripped — losing
    /// "(Dirty)" or "(Intro)" off a filename would be worse than the bug.
    @Test func keepsDJMeaningfulAnnotations() {
        let kept = [
            "Artist - Title (Dirty)",
            "Artist - Title (Clean)",
            "Artist - Title (Intro Dirty)",
            "Artist - Title (Extended Mix)",
            "Artist - Title (Acapella)",
            "Artist - Title (Instrumental)",
            "Artist - Title (feat. Someone)",
            "Artist - Title (Remix)"
        ]
        for videoTitle in kept {
            let parsed = YouTubeTitleParser.parse(videoTitle: videoTitle)
            let annotation = String(videoTitle.drop(while: { $0 != "(" }))
            #expect(parsed.title == "Title \(annotation)", "for \(videoTitle)")
        }
    }

    @Test func keepsMeaningfulAnnotationsWhileDroppingNoiseInTheSameTitle() {
        let parsed = YouTubeTitleParser.parse(
            videoTitle: "Artist - Title (Extended Mix) [Official Video]")

        #expect(parsed.artist == "Artist")
        #expect(parsed.title == "Title (Extended Mix)")
    }

    @Test func stripsQuotesAroundTheTitle() {
        #expect(YouTubeTitleParser.parse(videoTitle: "Artist - \"Title\"").title == "Title")
        #expect(YouTubeTitleParser.parse(videoTitle: "Artist - “Title”").title == "Title")
    }

    // MARK: - Refusing to guess

    /// The important half of the fix: when there's no artist to be found, say
    /// so rather than reaching for the channel name.
    @Test func returnsNoArtistWhenTheTitleHasNoSeparator() {
        let parsed = YouTubeTitleParser.parse(
            videoTitle: "Ella Fitzgerald and Duke Ellington It Don't Mean A Thing",
            uploader: "The Ed Sullivan Show")

        #expect(parsed.artist.isEmpty)
        #expect(parsed.title == "Ella Fitzgerald and Duke Ellington It Don't Mean A Thing")
    }

    /// A channel that prefixes its own name isn't naming an artist.
    @Test func ignoresAnArtistThatIsJustTheChannelName() {
        let parsed = YouTubeTitleParser.parse(
            videoTitle: "WorldstarHipHop - Some Song",
            uploader: "WorldstarHipHop")

        #expect(parsed.artist.isEmpty)
        #expect(parsed.title == "Some Song")
    }

    @Test func channelComparisonIgnoresPunctuationAndCase() {
        let parsed = YouTubeTitleParser.parse(
            videoTitle: "Gracie's Corner - Happy Birthday Song",
            uploader: "gracies corner")

        #expect(parsed.artist.isEmpty)
        #expect(parsed.title == "Happy Birthday Song")
    }

    @Test func aDanglingSeparatorIsNotASplit() {
        #expect(YouTubeTitleParser.parse(videoTitle: "Artist - ").artist.isEmpty)
        #expect(YouTubeTitleParser.parse(videoTitle: " - Title").artist.isEmpty)
    }

    // MARK: - Edge cases

    @Test func handlesAnEmptyOrWhitespaceTitle() {
        #expect(YouTubeTitleParser.parse(videoTitle: "").title.isEmpty)
        #expect(YouTubeTitleParser.parse(videoTitle: "   ").title.isEmpty)
    }

    /// A title that is nothing but decoration mustn't come back blank.
    @Test func aTitleThatIsEntirelyNoiseFallsBackToTheOriginal() {
        let parsed = YouTubeTitleParser.parse(videoTitle: "(Official Video)")

        #expect(parsed.title == "(Official Video)")
    }

    @Test func unbalancedBracketsDoNotSwallowTheTitle() {
        let parsed = YouTubeTitleParser.parse(videoTitle: "Artist - Title (Extended Mix")

        #expect(parsed.artist == "Artist")
        #expect(parsed.title.contains("Title"))
        #expect(parsed.title.contains("Extended Mix"))
    }

    @Test func collapsesWhitespaceLeftBehindByStripping() {
        let parsed = YouTubeTitleParser.parse(
            videoTitle: "Artist  -  Title   (Official Video)")

        #expect(parsed.artist == "Artist")
        #expect(parsed.title == "Title")
    }
}
