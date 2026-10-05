// EZLibrary — an open source toolkit for Serato DJ libraries.
// Copyright (C) 2026 Tawaun Lucas
// SPDX-License-Identifier: GPL-3.0-or-later
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. It is distributed WITHOUT ANY WARRANTY; see the GNU
// General Public License (LICENSE) for more details.

import Foundation
import Testing
@testable import EZLibraryCore

@Test func musicVideoTitlesAreExcludedFromSuggestions() {
    #expect(YouTubeAudioImportService.isLikelyMusicVideo(title: "Artist - Song (Official Video)"))
    #expect(YouTubeAudioImportService.isLikelyMusicVideo(title: "Artist - Song [Official Music Video]"))
    #expect(YouTubeAudioImportService.isLikelyMusicVideo(title: "Artist - Song (Video)"))
    #expect(YouTubeAudioImportService.isLikelyMusicVideo(title: "Song M/V"))
}

@Test func audioTitlesAreKeptInSuggestions() {
    #expect(!YouTubeAudioImportService.isLikelyMusicVideo(title: "Artist - Song (Official Audio)"))
    #expect(!YouTubeAudioImportService.isLikelyMusicVideo(title: "Artist - Song (Extended Mix)"))
    #expect(!YouTubeAudioImportService.isLikelyMusicVideo(title: "Artist - Song (Intro)"))
    #expect(!YouTubeAudioImportService.isLikelyMusicVideo(title: "Artist - Song (Someone Remix)"))
    #expect(!YouTubeAudioImportService.isLikelyMusicVideo(title: "Artist - Song (Lyric Video)"))
}

// MARK: - Upload year

/// A YouTube download is tagged with the year it was uploaded, read from
/// yt-dlp's `YYYYMMDD` upload date.
@Test func theUploadYearIsReadFromYTDLPsUploadDate() {
    typealias Info = YouTubeAudioImportService.VideoInfo
    #expect(Info.year(fromUploadDate: "20190314") == 2019)
    #expect(Info.year(fromUploadDate: " 20240101\n") == 2024)
    // yt-dlp prints "NA" when there is no date; that is no year, not year 0.
    #expect(Info.year(fromUploadDate: "NA") == nil)
    #expect(Info.year(fromUploadDate: "") == nil)
    #expect(Info.year(fromUploadDate: "0000") == nil)
}
