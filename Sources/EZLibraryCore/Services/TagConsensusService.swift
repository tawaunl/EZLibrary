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

/// Verifies tags by cross-checking independent music databases and requiring
/// them to agree. No API key, no AI, no cost — this is the tier every user gets.
///
/// The existing "Apply Top Hit" trusts one source's first result. That is the
/// root of the problem it causes: a single source's best guess for "Neverender"
/// is the original single, even when the file is a seven-minute remix. Agreement
/// is a much stronger signal than ranking. If iTunes, MusicBrainz, and Deezer
/// independently return the same album for a track, that album is almost
/// certainly right; if they disagree, no amount of ranking makes the top one
/// true, and the honest answer is "unverified".
///
/// Two further guards keep it from confidently proposing the wrong recording:
///
/// - **Duration.** A radio edit and an extended mix share a title and differ by
///   minutes. Candidates whose length cannot match the file are discarded
///   before anything is counted, which is the single most effective filter for
///   a DJ library.
/// - **Version descriptors.** "(Extended Mix)", "(Dirty)", "(Rampa Remix)" are
///   part of what the DJ owns. A consensus title never strips one.
public enum TagConsensusService {
    public static let engineName = "Cross-source consensus"

    public struct Options: Sendable {
        /// Include AcoustID fingerprint matches. Needs a key and `fpcalc`;
        /// skipped silently when either is missing.
        public var useFingerprint: Bool
        /// Which databases to consult. Defaults to the ones needing no
        /// credential, so the result does not depend on the user having keys.
        public var sourceSelection: OnlineTrackMetadataLookupService.SourceSelection
        /// How many independent sources must agree before a change is
        /// proposed. Two is the point of the whole design; one source agreeing
        /// with itself is just "top hit" again.
        public var minimumAgreeingSources: Int
        /// How far a candidate's length may differ from the file's before it is
        /// treated as a different recording. Generous enough to absorb fade-outs
        /// and silence trimming, tight enough to separate an edit from a mix.
        public var durationToleranceSeconds: Double
        public var maxConcurrentTracks: Int

        public init(
            useFingerprint: Bool = true,
            sourceSelection: OnlineTrackMetadataLookupService.SourceSelection = .freeSources,
            minimumAgreeingSources: Int = 2,
            durationToleranceSeconds: Double = 12,
            maxConcurrentTracks: Int = 3
        ) {
            self.useFingerprint = useFingerprint
            self.sourceSelection = sourceSelection
            self.minimumAgreeingSources = minimumAgreeingSources
            self.durationToleranceSeconds = durationToleranceSeconds
            self.maxConcurrentTracks = maxConcurrentTracks
        }
    }

    public typealias Event = TagVerificationEvent

    /// One value offered by one source, before any counting.
    struct Claim: Sendable, Hashable {
        let sourceName: String
        let value: String
        /// True when the claim comes from an audio fingerprint rather than a
        /// text search, which makes it evidence about *this* file specifically.
        let isFingerprint: Bool
    }

    /// How much a source's word is worth when counts tie. A fingerprint
    /// identifies the audio; the rest identify a search result.
    static func priority(ofSource name: String) -> Int {
        switch name {
        case "AcoustID":
            return 5
        case "MusicBrainz":
            return 4
        case "Discogs":
            return 3
        case "iTunes":
            return 2
        case "Deezer":
            return 1
        default:
            return 0
        }
    }

    // MARK: - Running

    public static func verify(
        tracks: [Track],
        options: Options = Options(),
        session: URLSession = OnlineTrackMetadataLookupService.defaultSession
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                guard !tracks.isEmpty else {
                    continuation.yield(.finished(verified: 0, failed: 0))
                    continuation.finish()
                    return
                }

                continuation.yield(.started(total: tracks.count))

                var verified = 0
                var failed = 0
                var iterator = tracks.makeIterator()
                let parallelism = max(1, min(options.maxConcurrentTracks, tracks.count))

                await withTaskGroup(of: (Track, Result<TrackTagVerification, Error>).self) { group in
                    func addNext() {
                        guard let track = iterator.next() else { return }
                        group.addTask {
                            do {
                                return (track, .success(try await verify(
                                    track: track,
                                    options: options,
                                    session: session
                                )))
                            } catch {
                                return (track, .failure(error))
                            }
                        }
                    }

                    for _ in 0..<parallelism {
                        addNext()
                    }

                    while let (track, result) = await group.next() {
                        if Task.isCancelled {
                            group.cancelAll()
                            break
                        }
                        switch result {
                        case let .success(verification):
                            verified += 1
                            continuation.yield(.verified(verification))
                        case let .failure(error):
                            failed += 1
                            continuation.yield(.failed(track: track, message: error.localizedDescription))
                        }
                        addNext()
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
        options: Options = Options(),
        session: URLSession = OnlineTrackMetadataLookupService.defaultSession
    ) async throws -> TrackTagVerification {
        // Both sources are best-effort. A throttled database or a missing
        // fingerprint key weakens the evidence, and weaker evidence simply
        // yields more "unverified" verdicts rather than a failed run.
        async let fingerprints: [AudioFingerprintSuggestion] = {
            guard options.useFingerprint else { return [] }
            return (try? await AudioFingerprintService.suggestMetadata(for: track, maxResults: 3)) ?? []
        }()

        async let candidates: [OnlineTrackMetadataCandidate] = {
            let query = OnlineTrackMetadataLookupService.Query(
                title: track.title,
                artist: track.artist,
                album: track.album
            )
            return (try? await OnlineTrackMetadataLookupService.lookup(
                query: query,
                sourceSelection: options.sourceSelection,
                maxResultsPerSource: 5,
                session: session
            )) ?? []
        }()

        // Reading the file's own tag is what makes artwork an *offer* rather
        // than a silent replacement: art that is already there is left alone
        // unless the user explicitly picks the new one.
        let hasArtwork = ArtworkFetchService.fileHasEmbeddedArtwork(at: track.fileURL)

        return consensus(
            for: track,
            fingerprintMatches: await fingerprints,
            candidates: await candidates,
            fileHasArtwork: hasArtwork,
            options: options
        )
    }

    // MARK: - The consensus itself

    /// Pure and offline: everything above this line only gathers the inputs.
    /// Keeping the judgement separate is what makes it testable against exact
    /// source combinations rather than against whatever the network returns.
    static func consensus(
        for track: Track,
        fingerprintMatches: [AudioFingerprintSuggestion],
        candidates: [OnlineTrackMetadataCandidate],
        fileHasArtwork: Bool = false,
        options: Options = Options()
    ) -> TrackTagVerification {
        let plausible = candidatesMatchingDuration(
            candidates,
            fileDuration: track.duration,
            tolerance: options.durationToleranceSeconds
        )
        let rejectedForLength = candidates.count - plausible.count

        let bestFingerprint = fingerprintMatches.max { ($0.confidence ?? 0) < ($1.confidence ?? 0) }
        let contributingSources = Set(
            plausible.map(\.source.displayName) + (fingerprintMatches.isEmpty ? [] : ["AcoustID"])
        )

        var verifications: [TagFieldVerification] = []
        for field in AITagVerificationService.verifiableFields {
            verifications.append(verdict(
                for: field,
                track: track,
                fingerprintMatches: fingerprintMatches,
                candidates: plausible,
                options: options
            ))
        }

        return TrackTagVerification(
            track: track,
            engineName: engineName,
            identityConfidence: identityConfidence(
                fingerprint: bestFingerprint,
                sourceCount: contributingSources.count
            ),
            identitySummary: identitySummary(
                track: track,
                fingerprint: bestFingerprint,
                sources: contributingSources,
                rejectedForLength: rejectedForLength
            ),
            fields: verifications,
            artwork: artworkProposal(from: plausible, fileHasArtwork: fileHasArtwork)
        )
    }

    /// Picks the cover art to offer, preferring the source that serves the
    /// largest image.
    ///
    /// Ordering here is by image size rather than by the source-authority order
    /// used for text, because every candidate has already survived the same
    /// filters — what differs is resolution. Deezer serves 1000px, iTunes 600px
    /// after upscaling the URL, MusicBrainz whatever the Cover Art Archive has.
    /// Embedded art is looked at on phones and controllers, so bigger wins.
    static func artworkProposal(
        from candidates: [OnlineTrackMetadataCandidate],
        fileHasArtwork: Bool
    ) -> ArtworkProposal? {
        let preference: [OnlineMetadataSource] = [.deezer, .itunes, .musicBrainz, .discogs]

        for source in preference {
            guard let match = candidates.first(where: { $0.source == source && $0.artworkURL != nil }),
                  let url = match.artworkURL else {
                continue
            }
            return ArtworkProposal(
                sourceName: source.displayName,
                url: url,
                fileIsMissingArtwork: !fileHasArtwork,
                albumTitle: match.album
            )
        }
        return nil
    }

    /// Drops candidates whose length rules them out as this recording.
    ///
    /// Candidates that report no duration are kept: an unknown length is not
    /// evidence of a mismatch, and discarding them would throw away every
    /// MusicBrainz and Discogs result, which do not carry one here.
    static func candidatesMatchingDuration(
        _ candidates: [OnlineTrackMetadataCandidate],
        fileDuration: TimeInterval?,
        tolerance: Double
    ) -> [OnlineTrackMetadataCandidate] {
        guard let fileDuration, fileDuration > 0 else { return candidates }
        return candidates.filter { candidate in
            guard let candidateDuration = candidate.durationSeconds, candidateDuration > 0 else { return true }
            return abs(candidateDuration - fileDuration) <= tolerance
        }
    }

    private static func verdict(
        for field: TagIntegrityAudit.Field,
        track: Track,
        fingerprintMatches: [AudioFingerprintSuggestion],
        candidates: [OnlineTrackMetadataCandidate],
        options: Options
    ) -> TagFieldVerification {
        let currentValue = AITagVerificationService.currentValue(of: field, in: track)
        let claims = claims(for: field, fingerprintMatches: fingerprintMatches, candidates: candidates)

        let resolved = field == .year ? yearConsensus(from: claims) : winningValue(from: claims)
        guard let winner = resolved else {
            return TagFieldVerification(
                field: field,
                verdict: .unverified,
                currentValue: currentValue,
                proposedValue: "",
                confidence: 0,
                evidence: "No source offered a value for this field."
            )
        }

        let agreeingSources = winner.sources
        let sourceList = formattedList(agreeingSources.sorted { priority(ofSource: $0) > priority(ofSource: $1) })
        let fingerprintAgrees = winner.sources.contains("AcoustID")

        // The proposal is built from the winning value, then re-dressed with
        // any DJ descriptor the current title carries — the databases return
        // the plain song title and dropping "(Extended Mix)" would be a
        // regression disguised as a correction.
        let proposal = field == .title
            ? OnlineTrackMetadataLookupService.titlePreservingDescriptors(from: winner.value, original: track.title)
            : winner.value

        if TagIntegrityAudit.normalize(proposal) == TagIntegrityAudit.normalize(currentValue),
           !currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return TagFieldVerification(
                field: field,
                verdict: .correct,
                currentValue: currentValue,
                proposedValue: "",
                confidence: confidence(agreeing: agreeingSources.count, fingerprintAgrees: fingerprintAgrees),
                evidence: "\(sourceList) agree with the current value."
            )
        }

        // Filling a blank is a different risk from overwriting a value someone
        // chose, so one source is allowed to *suggest* into an empty field. The
        // confidence that carries (0.5) sits below the auto-apply bar, so it
        // surfaces in the review sheet without a bulk run writing it unseen.
        let isEmptyField = currentValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let requiredSources = isEmptyField ? 1 : options.minimumAgreeingSources

        guard agreeingSources.count >= requiredSources else {
            return TagFieldVerification(
                field: field,
                verdict: .unverified,
                currentValue: currentValue,
                proposedValue: "",
                confidence: confidence(agreeing: agreeingSources.count, fingerprintAgrees: fingerprintAgrees),
                evidence: agreeingSources.count == 1
                    ? "Only \(sourceList) offered \"\(proposal)\" — not enough agreement to change it."
                    : "Sources disagreed on this field."
            )
        }

        return TagFieldVerification(
            field: field,
            verdict: .incorrect,
            currentValue: currentValue,
            proposedValue: proposal,
            confidence: confidence(agreeing: agreeingSources.count, fingerprintAgrees: fingerprintAgrees),
            evidence: evidenceText(
                isEmptyField: isEmptyField,
                sourceList: sourceList,
                proposal: proposal,
                agreeingCount: agreeingSources.count
            )
        )
    }

    static func evidenceText(
        isEmptyField: Bool,
        sourceList: String,
        proposal: String,
        agreeingCount: Int
    ) -> String {
        if isEmptyField {
            return agreeingCount == 1
                ? "Field is empty; \(sourceList) says it should be \"\(proposal)\"."
                : "Field is empty; \(sourceList) agree it should be \"\(proposal)\"."
        }
        return "\(sourceList) agree on \"\(proposal)\"."
    }

    static func claims(
        for field: TagIntegrityAudit.Field,
        fingerprintMatches: [AudioFingerprintSuggestion],
        candidates: [OnlineTrackMetadataCandidate]
    ) -> [Claim] {
        var claims: [Claim] = []

        for match in fingerprintMatches {
            let value = fingerprintValue(of: field, in: match)
            guard !value.isEmpty else { continue }
            claims.append(Claim(sourceName: "AcoustID", value: value, isFingerprint: true))
        }

        for candidate in candidates {
            let value = candidateValue(of: field, in: candidate)
            guard !value.isEmpty else { continue }
            claims.append(Claim(
                sourceName: candidate.source.displayName,
                value: value,
                isFingerprint: false
            ))
        }

        return claims
    }

    /// Year needs its own rule, because the sources are not answering the same
    /// question.
    ///
    /// Measured against the real APIs for one track (Daft Punk — Around The
    /// World): iTunes returns the date of *the release it matched* (1997),
    /// MusicBrainz returns the recording's *first* release date (1996), and
    /// Deezer's search results carry no date at all. Demanding exact agreement
    /// therefore left year unverified on almost everything — two sources, two
    /// different questions, one apparent disagreement, nothing proposed.
    ///
    /// Years within `tolerance` of each other are treated as corroborating the
    /// same record, and the earliest is taken: that is the original release
    /// year, which is the convention a music library tags to and the one
    /// MusicBrainz is reporting. A genuine gap — a 1977 original against a 2015
    /// remaster — is far wider than the tolerance, so those still do not merge,
    /// and the earliest is the right answer there anyway.
    static func yearConsensus(
        from claims: [Claim],
        tolerance: Int = 1
    ) -> (value: String, sources: Set<String>)? {
        let parsed = claims.compactMap { claim -> (year: Int, source: String)? in
            guard let year = Int(claim.value.prefix(4)), (1900...2100).contains(year) else { return nil }
            return (year, claim.sourceName)
        }
        guard !parsed.isEmpty else { return nil }

        // Cluster around each observed year, then keep whichever cluster the
        // most distinct sources land in.
        var best: (year: Int, sources: Set<String>)?
        for anchor in Set(parsed.map(\.year)).sorted() {
            let members = parsed.filter { abs($0.year - anchor) <= tolerance }
            let sources = Set(members.map(\.source))
            guard let earliest = members.map(\.year).min() else { continue }

            if let current = best {
                if sources.count > current.sources.count
                    || (sources.count == current.sources.count && earliest < current.year) {
                    best = (earliest, sources)
                }
            } else {
                best = (earliest, sources)
            }
        }

        guard let best else { return nil }
        return (String(best.year), best.sources)
    }

    /// Groups claims by their normalised value and picks the one the most
    /// *distinct sources* back. Counting sources rather than claims is the
    /// whole point: five iTunes rows saying the same thing is still one
    /// opinion, and treating it as five would rebuild the top-hit problem.
    static func winningValue(from claims: [Claim]) -> (value: String, sources: Set<String>)? {
        guard !claims.isEmpty else { return nil }

        var groups: [String: (display: String, sources: Set<String>)] = [:]
        for claim in claims {
            let key = TagIntegrityAudit.normalize(claim.value)
            guard !key.isEmpty else { continue }
            if var existing = groups[key] {
                existing.sources.insert(claim.sourceName)
                groups[key] = existing
            } else {
                groups[key] = (claim.value, [claim.sourceName])
            }
        }

        let ranked = groups.values.sorted { lhs, rhs in
            if lhs.sources.count != rhs.sources.count {
                return lhs.sources.count > rhs.sources.count
            }
            // Equal support: defer to the most authoritative backer, and fall
            // back to the value itself so the result never depends on
            // dictionary ordering.
            let lhsPriority = lhs.sources.map(priority(ofSource:)).max() ?? 0
            let rhsPriority = rhs.sources.map(priority(ofSource:)).max() ?? 0
            if lhsPriority != rhsPriority {
                return lhsPriority > rhsPriority
            }
            return lhs.display < rhs.display
        }

        guard let best = ranked.first else { return nil }
        return (best.display, best.sources)
    }

    static func confidence(agreeing: Int, fingerprintAgrees: Bool) -> Double {
        let base: Double
        switch agreeing {
        case 0:
            base = 0
        case 1:
            base = 0.5
        case 2:
            base = 0.75
        case 3:
            base = 0.88
        default:
            base = 0.93
        }
        return min(0.97, fingerprintAgrees ? base + 0.05 : base)
    }

    private static func identityConfidence(
        fingerprint: AudioFingerprintSuggestion?,
        sourceCount: Int
    ) -> Double {
        // A fingerprint identifies the audio, so it dominates. Without one,
        // identity rests on how many independent searches converged at all.
        if let score = fingerprint?.confidence, score > 0 {
            return min(0.97, score)
        }
        switch sourceCount {
        case 0:
            return 0
        case 1:
            return 0.45
        case 2:
            return 0.65
        default:
            return 0.75
        }
    }

    private static func identitySummary(
        track: Track,
        fingerprint: AudioFingerprintSuggestion?,
        sources: Set<String>,
        rejectedForLength: Int
    ) -> String {
        var parts: [String] = []

        if let fingerprint {
            let name = [fingerprint.artist, fingerprint.title]
                .filter { !$0.isEmpty }
                .joined(separator: " — ")
            parts.append(name.isEmpty
                ? "Audio fingerprint matched a recording."
                : "Audio fingerprint identifies this as \(name).")
        }

        if sources.isEmpty {
            parts.append("No source returned a usable match.")
        } else {
            let ordered = sources.sorted { priority(ofSource: $0) > priority(ofSource: $1) }
            parts.append("Checked \(formattedList(ordered)).")
        }

        if rejectedForLength > 0 {
            parts.append(
                "\(rejectedForLength) result\(rejectedForLength == 1 ? "" : "s") "
                + "ignored — the wrong length for this file."
            )
        }

        return parts.joined(separator: " ")
    }

    static func formattedList(_ items: [String]) -> String {
        switch items.count {
        case 0:
            return "no sources"
        case 1:
            return items[0]
        case 2:
            return "\(items[0]) and \(items[1])"
        default:
            return items.dropLast().joined(separator: ", ") + ", and \(items[items.count - 1])"
        }
    }

    private static func fingerprintValue(
        of field: TagIntegrityAudit.Field,
        in match: AudioFingerprintSuggestion
    ) -> String {
        switch field {
        case .title:
            return match.title
        case .artist:
            return match.artist
        case .album:
            return match.album
        case .genre:
            return match.genre
        case .year:
            return match.year.map(String.init) ?? ""
        case .comment:
            return ""
        }
    }

    private static func candidateValue(
        of field: TagIntegrityAudit.Field,
        in candidate: OnlineTrackMetadataCandidate
    ) -> String {
        switch field {
        case .title:
            return candidate.title
        case .artist:
            return candidate.artist
        case .album:
            return candidate.album
        case .genre:
            return candidate.genre
        case .year:
            return candidate.year.map(String.init) ?? ""
        case .comment:
            return ""
        }
    }
}
