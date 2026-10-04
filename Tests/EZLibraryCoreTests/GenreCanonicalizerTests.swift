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

// Hip hop and rap are stored as "Hip Hop" by every tag write.

@Test func everyHipHopAndRapSpellingIsWrittenAsHipHop() {
    for spelling in [
        "Hip-Hop", "Rap", "Hip-Hop/Rap", "Rap/Hip Hop", "HipHop/Rap", "hip hop",
        "RAP", "Rap & Hip-Hop", " Hip Hop/Rap ", "Hip Hop"
    ] {
        #expect(GenreCanonicalizer.forWriting(spelling) == "Hip Hop", "\(spelling)")
    }
}

@Test func otherGenresAreOnlyTrimmed() {
    #expect(GenreCanonicalizer.forWriting(" House ") == "House")
    // Not asked for: R&B and Drum & Bass spellings typed by hand are kept.
    #expect(GenreCanonicalizer.forWriting("DnB") == "DnB")
    #expect(GenreCanonicalizer.forWriting("RnB") == "RnB")
    // A different genre that mentions rap or hip hop is its own genre.
    #expect(GenreCanonicalizer.forWriting("Trip Hop") == "Trip Hop")
    #expect(GenreCanonicalizer.forWriting("Gangsta Rap") == "Gangsta Rap")
    #expect(GenreCanonicalizer.forWriting("") == "")
}

@Test func theMetadataUpdateEveryWriteUsesStoresHipHop() {
    // Built directly, the way manual edits and online lookups build it.
    var update = SeratoTrackMetadataUpdate(
        title: "Lose Yourself", artist: "Eminem", album: "8 Mile", genre: "Hip-Hop/Rap",
        comment: "", key: "", bpm: nil, year: 2002
    )
    #expect(update.genre == "Hip Hop")
    // And when a caller assigns it afterwards.
    update.genre = "Rap"
    #expect(update.genre == "Hip Hop")
}

@Test func aProposedSpellingOfTheSameGenreIsNotAChange() {
    func genre(current: String, proposed: String) -> TagFieldVerification {
        TagFieldVerification(field: .genre, verdict: .incorrect, currentValue: current,
                             proposedValue: proposed, confidence: 0.9, evidence: "")
    }
    #expect(!genre(current: "Hip Hop", proposed: "Hip-Hop/Rap").isChange)
    #expect(genre(current: "", proposed: "Hip-Hop/Rap").proposedValue == "Hip Hop")
    // A "Rap" tag still gets fixed, and shows as "Rap → Hip Hop".
    #expect(genre(current: "Rap", proposed: "Hip Hop").isChange)
    #expect(genre(current: "Rap", proposed: "Rap").proposedValue == "Hip Hop")
    #expect(genre(current: "Rap", proposed: "Rap").isChange)
    #expect(genre(current: "Hip Hop", proposed: "R&B").isChange)
}
