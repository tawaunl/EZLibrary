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

#if canImport(FoundationModels)
import FoundationModels

/// Verifies tags with Apple's on-device model. Free, private, no API key, no
/// per-track cost — but only on macOS 26 with Apple Intelligence available.
///
/// The on-device model is around three billion parameters and is explicitly not
/// built for world knowledge: asking it what year a record came out gets a
/// confident guess, which is worse than no answer. So it is never asked to
/// recall anything. It is given a tool that searches the same free music
/// databases the consensus engine uses, and its job is the part it is actually
/// good at — reading the evidence and deciding which candidate matches the file
/// in front of it, and where the current tags disagree.
///
/// That division is what makes "AI that searches the web" work with no API key:
/// the app does the searching, the model does the judging, and everything stays
/// on the machine.
@available(macOS 26.0, *)
public enum OnDeviceTagVerificationService {
    public static let engineName = "Apple on-device model"

    public enum OnDeviceError: LocalizedError {
        case deviceNotEligible
        case appleIntelligenceNotEnabled
        case modelNotReady
        case unusableResponse(String)

        public var errorDescription: String? {
            switch self {
            case .deviceNotEligible:
                return "This Mac can't run Apple's on-device model. It needs Apple silicon with Apple Intelligence support."
            case .appleIntelligenceNotEnabled:
                return "Apple Intelligence is turned off. Enable it in System Settings → Apple Intelligence & Siri, then try again."
            case .modelNotReady:
                return "Apple's on-device model is still downloading or preparing. Try again in a few minutes."
            case let .unusableResponse(detail):
                return "The on-device model returned something unusable: \(detail)"
            }
        }

        public var recoverySuggestion: String? {
            switch self {
            case .deviceNotEligible:
                return "Use the free cross-source consensus check instead — it works on every Mac."
            case .appleIntelligenceNotEnabled:
                return "Turn on Apple Intelligence in System Settings."
            case .modelNotReady:
                return "Wait for the model to finish preparing, then run the check again."
            case .unusableResponse:
                return "Try again, or switch to the cross-source consensus check."
            }
        }
    }

    /// Whether this engine can run right now, and why not when it cannot.
    public static var availabilityError: OnDeviceError? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case let .unavailable(reason):
            switch reason {
            case .deviceNotEligible:
                return .deviceNotEligible
            case .appleIntelligenceNotEnabled:
                return .appleIntelligenceNotEnabled
            case .modelNotReady:
                return .modelNotReady
            @unknown default:
                return .modelNotReady
            }
        @unknown default:
            return .modelNotReady
        }
    }

    public static var isAvailable: Bool {
        availabilityError == nil
    }

    // MARK: - The search tool

    /// The model's only route to facts. Everything it knows about a release, it
    /// learns by calling this.
    struct MusicDatabaseSearchTool: Tool {
        let name = "search_music_databases"
        let description = """
        Search music databases (iTunes, MusicBrainz, Deezer) for a song and get back \
        the title, artist, album, genre, release year, and length that each database \
        holds. Use this whenever you need a fact about a release. Never rely on memory.
        """

        let session: URLSession
        let sourceSelection: OnlineTrackMetadataLookupService.SourceSelection

        @Generable
        struct Arguments {
            @Guide(description: "The song title to search for, without any remix or version wording.")
            var title: String
            @Guide(description: "The artist name, or an empty string if unknown.")
            var artist: String
        }

        func call(arguments: Arguments) async throws -> String {
            let query = OnlineTrackMetadataLookupService.Query(
                title: arguments.title,
                artist: arguments.artist,
                album: ""
            )
            let candidates = (try? await OnlineTrackMetadataLookupService.lookup(
                query: query,
                sourceSelection: sourceSelection,
                maxResultsPerSource: 4,
                session: session
            )) ?? []

            guard !candidates.isEmpty else {
                return "No database returned a match for that search."
            }

            // Compact lines rather than JSON: this text goes straight into a
            // small model's context, where every token spent on punctuation is
            // a token not spent on the actual evidence.
            return candidates.prefix(12).map { candidate in
                var parts = ["[\(candidate.source.displayName)]"]
                let artist = candidate.artist.isEmpty ? "?" : candidate.artist
                let title = candidate.title.isEmpty ? "?" : candidate.title
                parts.append("\(artist) - \(title)")
                if !candidate.album.isEmpty { parts.append("album: \(candidate.album)") }
                if !candidate.genre.isEmpty { parts.append("genre: \(candidate.genre)") }
                if let year = candidate.year { parts.append("year: \(year)") }
                if let duration = candidate.durationSeconds, duration > 0 {
                    parts.append("length: \(Int(duration) / 60)m\(Int(duration) % 60)s")
                }
                return parts.joined(separator: " | ")
            }
            .joined(separator: "\n")
        }
    }

    // MARK: - Guided output

    /// Coarse confidence, not a probability.
    ///
    /// Asking a three-billion-parameter model for a 0-1 float produced numbers
    /// that were not merely uncalibrated but inverted — in a live run it
    /// returned 0.00 on exactly the verdicts it was proposing to change and
    /// 1.00 on the ones it was leaving alone. Three named levels are something
    /// a small model can actually place a judgement in, and guided generation
    /// makes the value a hard constraint rather than a request.
    @Generable
    enum VerdictConfidence: String {
        case high
        case medium
        case low

        var score: Double {
            switch self {
            case .high:
                return 0.9
            case .medium:
                return 0.7
            case .low:
                return 0.4
            }
        }
    }

    @Generable
    enum VerdictField: String {
        case title
        case artist
        case album
        case genre
        case year
    }

    @Generable
    enum VerdictKind: String {
        case correct
        case incorrect
        case unverified
    }

    @Generable
    struct FieldVerdict {
        var field: VerdictField
        var verdict: VerdictKind
        @Guide(description: "The corrected value. Empty string unless verdict is incorrect.")
        var proposedValue: String
        @Guide(description: """
        Use high when a database returned this exact value. Use medium when the databases         only partly agree. Use low only when you are guessing beyond what a database returned.
        """)
        var confidence: VerdictConfidence
        @Guide(description: "One short sentence naming the database that supports this.")
        var evidence: String
    }

    @Generable
    struct TrackVerdict {
        @Guide(description: "One sentence naming the recording you believe this file is.")
        var identitySummary: String
        @Guide(description: "How confident you are that you identified the right recording.")
        var identityConfidence: VerdictConfidence
        @Guide(description: "One entry for each of the five fields: title, artist, album, genre, year.")
        var fields: [FieldVerdict]
    }

    // MARK: - Running

    public static func verify(
        tracks: [Track],
        sourceSelection: OnlineTrackMetadataLookupService.SourceSelection = .freeSources,
        session: URLSession = OnlineTrackMetadataLookupService.defaultSession
    ) -> AsyncStream<TagVerificationEvent> {
        AsyncStream { continuation in
            let task = Task {
                guard !tracks.isEmpty else {
                    continuation.yield(.finished(verified: 0, failed: 0))
                    continuation.finish()
                    return
                }

                if let unavailable = availabilityError {
                    continuation.yield(.aborted(message: unavailable.localizedDescription))
                    continuation.finish()
                    return
                }

                continuation.yield(.started(total: tracks.count))

                var verified = 0
                var failed = 0

                // Deliberately serial. The on-device model runs on this Mac's
                // own neural engine, so parallel sessions contend for the same
                // hardware and finish no sooner while making the machine
                // unusable for anything else.
                for track in tracks {
                    if Task.isCancelled { break }
                    do {
                        let result = try await verify(
                            track: track,
                            sourceSelection: sourceSelection,
                            session: session
                        )
                        verified += 1
                        continuation.yield(.verified(result))
                    } catch {
                        failed += 1
                        continuation.yield(.failed(track: track, message: error.localizedDescription))
                    }
                }

                continuation.yield(.finished(verified: verified, failed: failed))
                continuation.finish()
            }

            continuation.onTermination = { _ in
                task.cancel()
            }
        }
    }

    public static func verify(
        track: Track,
        sourceSelection: OnlineTrackMetadataLookupService.SourceSelection = .freeSources,
        session: URLSession = OnlineTrackMetadataLookupService.defaultSession
    ) async throws -> TrackTagVerification {
        if let unavailable = availabilityError {
            throw unavailable
        }

        let tool = MusicDatabaseSearchTool(session: session, sourceSelection: sourceSelection)
        let modelSession = LanguageModelSession(tools: [tool], instructions: instructions)

        let response = try await modelSession.respond(
            to: prompt(for: track),
            generating: TrackVerdict.self
        )

        return verification(from: response.content, for: track)
    }

    static let instructions = """
    You check whether a DJ's music file has the right tags.

    You do not know anything about releases from memory, and you must never guess one. \
    Every fact you use comes from the search_music_databases tool. Call it before judging \
    any field.

    Rules:
    - Keep version wording. "Extended Mix", "Radio Edit", "Dirty", "Clean", "Acapella" and \
    remix credits are part of the title of the version this DJ owns. Never remove one.
    - The title field holds the song name only. Never put the artist name in it, even when \
    the file name is written that way.
    - Length matters. If the file is minutes longer than a database result, it is a \
    different version and that result's album and year do not apply to it.
    - Mark a field "incorrect" only when a database clearly contradicts it. Say which \
    database in the evidence.
    - Mark a field "unverified" when the databases disagree, return nothing, or do not \
    cover it. An empty tag you cannot fill is "unverified", not "incorrect".
    - Mark a field "correct" when a database agrees with what is already there.
    - A tag that is currently empty can never be "correct". Either a database gives you \
    the value, and it is "incorrect" with that value proposed, or it is "unverified".
    - Only cite a database that actually returned the value you relied on. If a search \
    result carried no genre, it is not evidence about the genre.
    - Leave proposedValue as an empty string unless the verdict is "incorrect".
    """

    static func prompt(for track: Track) -> String {
        var lines: [String] = []
        lines.append("File name: \(track.fileURL.lastPathComponent)")
        if let duration = track.duration, duration > 0 {
            lines.append("File length: \(Int(duration) / 60)m\(Int(duration) % 60)s")
        }
        lines.append("Current tags:")
        lines.append("- title: \(displayValue(track.title))")
        lines.append("- artist: \(displayValue(track.artist))")
        lines.append("- album: \(displayValue(track.album))")
        lines.append("- genre: \(displayValue(track.genre))")
        lines.append("- year: \(track.year.map(String.init) ?? "(empty)")")
        lines.append("")
        lines.append("Search the databases for this song, then give a verdict for each of the five fields.")
        return lines.joined(separator: "\n")
    }

    private static func displayValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty)" : trimmed
    }

    /// Maps the model's guided output onto the shared verification shape.
    ///
    /// Guided generation constrains the *structure*, not the vocabulary, so a
    /// small model can still answer "Correct." where "correct" was asked for.
    /// Unrecognised field names and verdicts are dropped rather than guessed at.
    static func verification(
        from verdict: TrackVerdict,
        for track: Track
    ) -> TrackTagVerification {
        var fields: [TagFieldVerification] = []

        for entry in verdict.fields {
            guard let field = TagIntegrityAudit.Field(rawValue: entry.field.rawValue) else { continue }
            let currentValue = AITagVerificationService.currentValue(of: field, in: track)
            var parsed = mapped(entry.verdict)

            // An empty tag cannot be "correct" — there is nothing there to be
            // right. A live run returned exactly that for an empty genre,
            // citing a source that carries no genre at all, and taking it at
            // face value reports a missing tag as verified.
            if parsed == .correct, currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                parsed = .unverified
            }

            let proposal = parsed == .incorrect
                ? sanitized(entry.proposedValue, for: field, track: track)
                : ""

            fields.append(TagFieldVerification(
                field: field,
                verdict: proposal.isEmpty && parsed == .incorrect ? .unverified : parsed,
                currentValue: currentValue,
                proposedValue: proposal,
                confidence: entry.confidence.score,
                evidence: entry.evidence
            ))
        }

        return TrackTagVerification(
            track: track,
            engineName: engineName,
            identityConfidence: verdict.identityConfidence.score,
            identitySummary: verdict.identitySummary,
            fields: fields
        )
    }

    /// Repairs the small-model mistakes that would otherwise be written into
    /// the user's tags.
    ///
    /// A three-billion-parameter model reliably reproduces the shape of its
    /// input, and its input includes the file name — so asked for a title it
    /// returns "Justice - D.A.N.C.E. (Extended Mix)", artist and all. That is
    /// observed behaviour from a live run, not a hypothetical, and applying it
    /// would corrupt the very field it was asked to correct. The prompt asks
    /// for the right thing; this makes sure of it.
    static func sanitized(
        _ rawValue: String,
        for field: TagIntegrityAudit.Field,
        track: Track
    ) -> String {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return "" }

        if field == .title {
            value = strippingArtistPrefix(from: value, artist: track.artist)
            // A descriptor the model dropped is re-attached, exactly as the
            // consensus engine does: losing "(Extended Mix)" is a corruption
            // dressed up as a correction.
            value = OnlineTrackMetadataLookupService.titlePreservingDescriptors(
                from: value,
                original: track.title
            )
        }

        if field == .year, Int(value.prefix(4)) == nil {
            return ""
        }

        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes a leading "Artist - " from a proposed title.
    static func strippingArtistPrefix(from title: String, artist: String) -> String {
        let artistName = artist.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !artistName.isEmpty else { return title }

        for separator in [" - ", " – ", " — ", ": "] {
            let prefix = artistName + separator
            if title.lowercased().hasPrefix(prefix.lowercased()) {
                let stripped = String(title.dropFirst(prefix.count))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                return stripped.isEmpty ? title : stripped
            }
        }
        return title
    }

    static func mapped(_ kind: VerdictKind) -> TagVerdict {
        switch kind {
        case .correct:
            return .correct
        case .incorrect:
            return .incorrect
        case .unverified:
            return .unverified
        }
    }
}
#endif
