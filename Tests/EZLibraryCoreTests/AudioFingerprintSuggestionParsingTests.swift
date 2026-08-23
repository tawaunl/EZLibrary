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

private func results(_ json: String) -> Any? {
    let data = Data(json.utf8)
    guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
    return root["results"]
}

/// One fingerprint routinely maps to many MusicBrainz recordings of the same
/// song — one per release it appeared on. This is what AcoustID actually
/// returns for a well-known track.
private let sameSongManyReleases = """
{"status": "ok", "results": [
  {"score": 0.96, "recordings": [
    {"title": "Neverender", "artists": [{"name": "Justice"}],
     "releases": [{"title": "Hyperdrama", "year": 2024}]},
    {"title": "Neverender", "artists": [{"name": "Justice"}],
     "releases": [{"title": "Hyperdrama (Japan Edition)", "year": 2025}]},
    {"title": "Neverender", "artists": [{"name": "Justice"}],
     "releases": [{"title": "Summer Hits 2025", "year": 2025}]}
  ]},
  {"score": 0.71, "recordings": [
    {"title": "Neverender (Erol Alkan Remix)", "artists": [{"name": "Justice"}],
     "releases": [{"title": "Neverender Remixes", "year": 2024}]}
  ]}
]}
"""

@Test func repeatedReleasesOfOneRecordingCollapseToASingleSuggestion() {
    let suggestions = AudioFingerprintService.parseSuggestionsFromResults(results(sameSongManyReleases))

    // Previously this returned three near-identical "Neverender" rows and the
    // remix never survived truncation to maxResults.
    #expect(suggestions.count == 2)
    #expect(suggestions[0].title == "Neverender")
    #expect(suggestions[1].title == "Neverender (Erol Alkan Remix)")
}

@Test func theEarliestDatedReleaseIsPreferredForTheAlbum() {
    let suggestions = AudioFingerprintService.parseSuggestionsFromResults(results(sameSongManyReleases))
    // Not the Japan edition or the compilation, both of which are later.
    #expect(suggestions.first?.album == "Hyperdrama")
}

@Test func suggestionsAreOrderedByFingerprintScore() {
    let json = """
    {"results": [
      {"score": 0.42, "recordings": [{"title": "Weak Match", "artists": [{"name": "A"}]}]},
      {"score": 0.99, "recordings": [{"title": "Strong Match", "artists": [{"name": "B"}]}]}
    ]}
    """
    let suggestions = AudioFingerprintService.parseSuggestionsFromResults(results(json), minimumScore: 0)
    #expect(suggestions.map(\.title) == ["Strong Match", "Weak Match"])
}

@Test func noiseLevelMatchesAreDroppedWhenSomethingBetterExists() {
    let json = """
    {"results": [
      {"score": 0.95, "recordings": [{"title": "Real Match", "artists": [{"name": "A"}]}]},
      {"score": 0.18, "recordings": [{"title": "Noise", "artists": [{"name": "B"}]}]}
    ]}
    """
    let suggestions = AudioFingerprintService.parseSuggestionsFromResults(results(json))
    #expect(suggestions.map(\.title) == ["Real Match"])
}

@Test func theBestMatchSurvivesEvenWhenEveryScoreIsWeak() {
    // Reporting "no match" when a weak match exists hides information the user
    // can judge for themselves — the confidence is shown alongside it.
    let json = """
    {"results": [
      {"score": 0.31, "recordings": [{"title": "Faint", "artists": [{"name": "A"}]}]},
      {"score": 0.12, "recordings": [{"title": "Fainter", "artists": [{"name": "B"}]}]}
    ]}
    """
    let suggestions = AudioFingerprintService.parseSuggestionsFromResults(results(json))
    #expect(suggestions.count == 1)
    #expect(suggestions[0].title == "Faint")
}

@Test func aStrongerDuplicateReplacesAWeakerOne() {
    let json = """
    {"results": [
      {"score": 0.55, "recordings": [{"title": "Song", "artists": [{"name": "A"}],
        "releases": [{"title": "Weak Album", "year": 2001}]}]},
      {"score": 0.91, "recordings": [{"title": "Song", "artists": [{"name": "A"}],
        "releases": [{"title": "Strong Album", "year": 2000}]}]}
    ]}
    """
    let suggestions = AudioFingerprintService.parseSuggestionsFromResults(results(json))
    #expect(suggestions.count == 1)
    #expect(suggestions[0].confidence == 0.91)
    #expect(suggestions[0].album == "Strong Album")
}

@Test func recordingsWithNoUsableTextAreSkipped() {
    let json = """
    {"results": [{"score": 0.9, "recordings": [
      {"title": "   ", "artists": [{"name": ""}]},
      {"title": "Real", "artists": [{"name": "A"}]}
    ]}]}
    """
    let suggestions = AudioFingerprintService.parseSuggestionsFromResults(results(json))
    #expect(suggestions.map(\.title) == ["Real"])
}

@Test func aResponseWithNoResultsParsesToNothing() {
    #expect(AudioFingerprintService.parseSuggestionsFromResults(results("{\"results\": []}")).isEmpty)
    #expect(AudioFingerprintService.parseSuggestionsFromResults(nil).isEmpty)
}

@Test func releasesWithoutDatesStillProduceAnAlbum() {
    let json = """
    {"results": [{"score": 0.9, "recordings": [
      {"title": "Song", "artists": [{"name": "A"}], "releases": [{"title": "Undated Album"}]}
    ]}]}
    """
    #expect(AudioFingerprintService.parseSuggestionsFromResults(results(json)).first?.album == "Undated Album")
}
