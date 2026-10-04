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

// Cover art for the AI engines' answers: shared by the cloud and on-device
// engines, so tested once here on the step they both finish with.

private func artTrack(album: String = "") -> Track {
    Track(
        seratoStoredPath: "Music/M83 - Midnight City.mp3",
        fileURL: URL(fileURLWithPath: "/nonexistent/M83 - Midnight City.mp3"),
        title: "Midnight City", artist: "M83", album: album, genre: "", comment: "", year: 2011
    )
}

private func withArt(_ source: OnlineMetadataSource, _ album: String) -> OnlineTrackMetadataCandidate {
    OnlineTrackMetadataCandidate(
        source: source, title: "Midnight City", artist: "M83", album: album, genre: "", year: 2011, bpm: nil,
        artworkURL: URL(string: "https://example.com/\(source.rawValue)/\(album.count).jpg")
    )
}

private func aiResult(track: Track, proposedAlbum: String?, identity: Double = 0.9) -> TrackTagVerification {
    var fields: [TagFieldVerification] = []
    if let proposedAlbum {
        fields.append(TagFieldVerification(
            field: .album, verdict: .incorrect, currentValue: track.album,
            proposedValue: proposedAlbum, confidence: 0.9, evidence: "Wikipedia."
        ))
    }
    return TrackTagVerification(
        track: track, engineName: "Model", identityConfidence: identity,
        identitySummary: "M83 – Midnight City", fields: fields
    )
}

@Test func artIsOfferedForTheAlbumTheModelSettledOn() {
    let result = TagVerificationCoordinator.attachingArtwork(
        to: aiResult(track: artTrack(), proposedAlbum: "Hurry Up, We're Dreaming"),
        candidates: [withArt(.itunes, "Midnight City - EP"), withArt(.itunes, "Hurry Up, We're Dreaming")],
        fileHasArtwork: false
    )
    #expect(result.artwork?.albumTitle == "Hurry Up, We're Dreaming")
    #expect(result.artwork?.fileIsMissingArtwork == true)
}

@Test func noArtWhenNoResultIsForThatAlbum() {
    // Unlike the free engine, never falls back to another release's cover.
    let result = TagVerificationCoordinator.attachingArtwork(
        to: aiResult(track: artTrack(), proposedAlbum: "Hurry Up, We're Dreaming"),
        candidates: [withArt(.deezer, "Midnight City (Remix EP)"), withArt(.itunes, "Midnight City - EP")],
        fileHasArtwork: false
    )
    #expect(result.artwork == nil)
}

@Test func theAlbumAlreadyTaggedIsUsedWhenTheModelProposesNoChange() {
    let result = TagVerificationCoordinator.attachingArtwork(
        to: aiResult(track: artTrack(album: "Hurry Up, We're Dreaming"), proposedAlbum: nil),
        candidates: [withArt(.itunes, "Hurry Up, We're Dreaming")],
        fileHasArtwork: true
    )
    #expect(result.artwork != nil)
    #expect(result.artwork?.fileIsMissingArtwork == false)
}

@Test func aSingleOnlySongGetsTheSinglesCover() {
    let result = TagVerificationCoordinator.attachingArtwork(
        to: aiResult(track: artTrack(), proposedAlbum: "Midnight City"),
        candidates: [withArt(.itunes, "Midnight City - EP")],
        fileHasArtwork: false
    )
    #expect(result.artwork?.albumTitle == "Midnight City - EP")
}

@Test func theLargerDeezerCoverWinsOnTheSameAlbum() {
    let result = TagVerificationCoordinator.attachingArtwork(
        to: aiResult(track: artTrack(), proposedAlbum: "Hurry Up, We're Dreaming"),
        candidates: [withArt(.itunes, "Hurry Up, We're Dreaming"), withArt(.deezer, "Hurry Up, We're Dreaming")],
        fileHasArtwork: false
    )
    #expect(result.artwork?.sourceName == OnlineMetadataSource.deezer.displayName)
}

@Test func noArtWhenTheModelIsUnsureItFoundTheSong() {
    // The on-device model's "low" identity is 0.4.
    let result = TagVerificationCoordinator.attachingArtwork(
        to: aiResult(track: artTrack(), proposedAlbum: "Hurry Up, We're Dreaming", identity: 0.4),
        candidates: [withArt(.itunes, "Hurry Up, We're Dreaming")],
        fileHasArtwork: false
    )
    #expect(result.artwork == nil)
}

@Test func artMatchesAnAlbumFilledInFromTheDatabases() {
    // The model left the album blank; the shared finishing step fills it from
    // the results and then finds art for that filled-in album.
    let candidates = [withArt(.itunes, "Hurry Up, We're Dreaming"), withArt(.deezer, "Hurry Up, We're Dreaming")]
    let result = TagVerificationCoordinator.finishing(
        aiResult(track: artTrack(), proposedAlbum: nil),
        candidates: candidates,
        fileHasArtwork: false
    )
    #expect(result.proposedChanges.first { $0.field == .album }?.proposedValue == "Hurry Up, We're Dreaming")
    #expect(result.artwork?.albumTitle == "Hurry Up, We're Dreaming")
}
