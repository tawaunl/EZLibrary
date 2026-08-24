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
        Search music databases (iTunes, MusicBrainz, Deezer, Discogs, Wikipedia) for a song \
        and get back the title, artist, album, genre, release year, and length that each \
        database holds. Wikipedia is the most reliable for the original album a song first \
        appeared on. Use this whenever you need a fact about a release. Never rely on memory.
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
            return OnDeviceTagVerificationService.formattedCandidates(candidates)
        }
    }

    /// Compact one-line-per-candidate text. It goes straight into a small
    /// model's context, where every token spent on punctuation is a token not
    /// spent on the evidence.
    static func formattedCandidates(_ candidates: [OnlineTrackMetadataCandidate], limit: Int = 12) -> String {
        candidates.prefix(limit).map { candidate in
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
        sourceSelection: OnlineTrackMetadataLookupService.SourceSelection = .all,
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
        sourceSelection: OnlineTrackMetadataLookupService.SourceSelection = .all,
        session: URLSession = OnlineTrackMetadataLookupService.defaultSession
    ) async throws -> TrackTagVerification {
        if let unavailable = availabilityError {
            throw unavailable
        }

        // Read once: the file's own ID3 tags are both what the search uses and
        // what the model judges, the same rule the consensus and cloud engines
        // follow. The library row can be stale.
        let fileTags = await AudioFileTagReader.readTags(from: track.fileURL)

        // Pre-fetch the database candidates the app would search for anyway and
        // hand them to the model, rather than trusting a small model to search
        // well. The tool stays registered for a follow-up search when none of
        // the pre-fetched candidates fit.
        let candidates = (try? await OnlineTrackMetadataLookupService.lookup(
            query: TagConsensusService.searchQuery(for: track, fileTags: fileTags),
            sourceSelection: sourceSelection,
            maxResultsPerSource: 5,
            session: session,
            deduplicate: false
        )) ?? []

        let tool = MusicDatabaseSearchTool(session: session, sourceSelection: sourceSelection)
        let modelSession = LanguageModelSession(tools: [tool], instructions: instructions)

        let response = try await modelSession.respond(
            to: prompt(for: track, fileTags: fileTags, candidates: candidates),
            generating: TrackVerdict.self
        )

        return verification(from: response.content, for: track)
    }

    static let instructions = """
    You check whether a DJ's music file has the right tags. Work in this order:

    1. Read the database results provided below the tags. They were already searched for you. \
    Only if none of them is this recording — or none were found — call search_music_databases, \
    with just the title, then the artist and the most distinctive word of the title.
    2. Pick the matching version. Among the results, choose the one whose length is closest to \
    the file's. A result minutes longer or shorter is a different version, and its album and \
    year do not apply to this file.
    3. Judge each of the five fields against that matched result.

    You know nothing about releases from memory and must never guess one. Every value you \
    propose has to come from a search result you actually saw.

    Rules:
    - Keep version wording. "Extended Mix", "Radio Edit", "Dirty", "Clean", "Acapella" and \
    remix credits are part of the title of the version this DJ owns. Never remove one.
    - The title field holds the song name only. Never put the artist name in it, even when \
    the file name is written that way. Judge from the ID3 tags, not the file name.
    - The artist field holds the credited performing artists. Do not move a remixer there \
    unless the release credits them there.
    - Any form of hip hop — "Hip-Hop/Rap", "Rap/Hip Hop", "hip hop", "rap" — is written exactly \
    "Hip Hop". Otherwise a genre must be an actual genre, at roughly the specificity the \
    library already uses.
    - A pure capitalization or punctuation difference is worth correcting only when the current \
    value is clearly malformed, such as ALL CAPS or missing spaces.
    - For a remix or edit outside electronic music, use the year the original song came out, not \
    the year of the remix. In electronic music a remix is its own release, so use its own year.
    - The year is often missing from the ID3 tag but present in the file name or the library. If \
    no database returns a year, propose the possible year shown rather than leaving it blank.
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

    static func prompt(
        for track: Track,
        fileTags: AudioFileTagReader.Tags,
        candidates: [OnlineTrackMetadataCandidate] = []
    ) -> String {
        // Prefer the file's own ID3 tag over the library's stored copy for
        // every field, so the model searches and judges from the file, not the
        // file name — which is shown only as a last-resort hint.
        func preferred(_ fileValue: String?, _ stored: String) -> String {
            let fromFile = fileValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return fromFile.isEmpty ? stored : fromFile
        }

        var lines: [String] = []
        lines.append("FILE NAME (weak hint only, never copy into a field): \(track.fileURL.lastPathComponent)")
        if let duration = track.duration, duration > 0 {
            lines.append("File length: \(Int(duration) / 60)m\(Int(duration) % 60)s")
        }
        lines.append("")
        lines.append("Current tags (from the file's ID3 tags — search with these, not the file name):")
        lines.append("- title: \(displayValue(preferred(fileTags.title, track.title)))")
        lines.append("- artist: \(displayValue(preferred(fileTags.artist, track.artist)))")
        lines.append("- album: \(displayValue(preferred(fileTags.album, track.album)))")
        lines.append("- genre: \(displayValue(preferred(fileTags.genre, track.genre)))")

        let effectiveYear = preferred(fileTags.year.map(String.init), track.year.map(String.init) ?? "")
        lines.append("- year: \(effectiveYear.isEmpty ? "(empty)" : effectiveYear)")
        // The year is often absent from the ID3 frame but present in the file
        // name or the library. Offer it so an empty year gets filled rather
        // than left blank.
        if effectiveYear.isEmpty, let fallback = TagConsensusService.fallbackReleaseYear(for: track) {
            lines.append("- possible year (from the file name/library; use it unless a database gives another): \(fallback)")
        }

        lines.append("")
        if candidates.isEmpty {
            lines.append("No database results were found for these tags. Call search_music_databases with a simpler query, or mark fields unverified.")
        } else {
            lines.append("Database results already found for this file (judge against these; only call search_music_databases if none of them is this recording):")
            lines.append(formattedCandidates(candidates))
        }
        lines.append("")
        lines.append("Give a verdict for each of the five fields.")
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

        // The model is asked to fill an empty year from the file name, but a
        // small model does not always. Deterministic backstop: if the year is
        // still blank and the file name or library carries one, propose it at a
        // review-level confidence so it surfaces rather than staying empty.
        fillEmptyYearFromFallback(&fields, track: track)

        return TrackTagVerification(
            track: track,
            engineName: engineName,
            identityConfidence: verdict.identityConfidence.score,
            identitySummary: verdict.identitySummary,
            fields: fields
        )
    }

    /// Backfills the year field from the file name or library when the model
    /// left it blank. Kept separate so it can be tested without a model.
    static func fillEmptyYearFromFallback(_ fields: inout [TagFieldVerification], track: Track) {
        let currentYear = AITagVerificationService.currentValue(of: .year, in: track)
        guard currentYear.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }

        let existing = fields.firstIndex { $0.field == .year }
        if let existing, fields[existing].verdict == .incorrect, !fields[existing].proposedValue.isEmpty {
            return
        }
        guard let fallback = TagConsensusService.fallbackReleaseYear(for: track) else { return }

        let filled = TagFieldVerification(
            field: .year,
            verdict: .incorrect,
            currentValue: currentYear,
            proposedValue: String(fallback),
            confidence: 0.5,
            evidence: "Year is empty; the file name suggests \(fallback)."
        )
        if let existing {
            fields[existing] = filled
        } else {
            fields.append(filled)
        }
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

    /// Removes the artist from a proposed title. Shared with the other engines
    /// and the write path so the rule holds everywhere.
    static func strippingArtistPrefix(from title: String, artist: String) -> String {
        OnlineTrackMetadataLookupService.titleWithoutArtist(title, artist: artist)
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
