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
        ///
        /// Off by default. Measured cost is about 0.3s per track (0.05s in
        /// `fpcalc`, the rest the AcoustID round trip) — small, but it buys
        /// nothing for the majority of tracks whose identity the databases
        /// already agree on. It earns its keep on files whose tags are too
        /// wrong to search with, so it is worth turning on for a rescue pass
        /// rather than for a whole library.
        public var useFingerprint: Bool
        /// Which databases to consult.
        ///
        /// Defaults to the fast pair (iTunes and Deezer). MusicBrainz has the
        /// best editorial data but paces callers to one request a second and
        /// its search latency has been measured anywhere from 0.6s to past the
        /// request timeout, which makes it the ceiling on a whole-library run.
        /// Deezer's album lookup now supplies the release year that used to be
        /// the reason MusicBrainz was indispensable.
        public var sourceSelection: OnlineTrackMetadataLookupService.SourceSelection
        /// How many independent sources must agree before a change is
        /// proposed. Two is the point of the whole design; one source agreeing
        /// with itself is just "top hit" again.
        public var minimumAgreeingSources: Int
        /// How far a candidate's length may differ from the file's before it is
        /// treated as a different recording. Generous enough to absorb fade-outs
        /// and silence trimming, tight enough to separate an edit from a mix.
        public var durationToleranceSeconds: Double
        /// How many tracks are verified at once.
        ///
        /// Zero means "decide from the sources", which is almost always right:
        /// the fast pair has no meaningful pacing, so width is free, while
        /// MusicBrainz serialises callers to one request a second and extra
        /// concurrency there only builds a queue.
        public var maxConcurrentTracks: Int

        public init(
            useFingerprint: Bool = false,
            sourceSelection: OnlineTrackMetadataLookupService.SourceSelection = .fastSources,
            minimumAgreeingSources: Int = 2,
            durationToleranceSeconds: Double = 12,
            maxConcurrentTracks: Int = 0
        ) {
            self.useFingerprint = useFingerprint
            self.sourceSelection = sourceSelection
            self.minimumAgreeingSources = minimumAgreeingSources
            self.durationToleranceSeconds = durationToleranceSeconds
            self.maxConcurrentTracks = maxConcurrentTracks
        }

        /// The width actually used, derived from the sources when not pinned.
        ///
        /// A rate-limited source is the ceiling regardless of how many tracks
        /// run at once, so widening past it just queues work; without one,
        /// throughput scales with width until the network gives up.
        var effectiveConcurrency: Int {
            guard maxConcurrentTracks <= 0 else { return maxConcurrentTracks }
            let paced: Set<OnlineMetadataSource> = [.musicBrainz, .discogs]
            let hasPacedSource = !Set(sourceSelection.enabledSources).isDisjoint(with: paced)
            return hasPacedSource ? 3 : 8
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
                let parallelism = max(1, min(options.effectiveConcurrency, tracks.count))

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

        // Searched from the file's own ID3 tags, not the library's copy of them
        // and never the filename. The database row can be stale — it is what
        // Serato read when the track was imported, and anything that has edited
        // the file since has not necessarily told Serato. The file is the
        // current truth about what the track claims to be.
        let fileTags = await AudioFileTagReader.readTags(from: track.fileURL)

        async let candidates: [OnlineTrackMetadataCandidate] = {
            let query = searchQuery(for: track, fileTags: fileTags)
            return (try? await OnlineTrackMetadataLookupService.lookup(
                query: query,
                sourceSelection: options.sourceSelection,
                // A deeper pool per source, because the duration filter throws
                // most of it away: for one real query only 1 of 9 candidates
                // was the right length, and the matching entry from the second
                // source sat just outside the top five.
                maxResultsPerSource: 12,
                session: session,
                // Never deduplicated here — see `lookup(deduplicate:)`. Folding
                // two sources' identical answers into one is precisely the
                // signal this engine exists to count.
                deduplicate: false
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

    /// The terms to search with.
    ///
    /// The file's own ID3 tags win over the library's stored copy wherever the
    /// file has a value; the stored copy fills the gaps. The filename is never
    /// used — it is evidence about the track, but it is the least reliable kind
    /// and searching by it turns "01 - track.mp3" into a query for nothing.
    static func searchQuery(
        for track: Track,
        fileTags: AudioFileTagReader.Tags
    ) -> OnlineTrackMetadataLookupService.Query {
        func preferred(_ fileValue: String?, _ storedValue: String) -> String {
            let fromFile = fileValue?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return fromFile.isEmpty ? storedValue : fromFile
        }

        return OnlineTrackMetadataLookupService.Query(
            title: preferred(fileTags.title, track.title),
            artist: preferred(fileTags.artist, track.artist),
            album: preferred(fileTags.album, track.album)
        )
    }

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
                titleAgreement: agreementCount(for: .title, fingerprintMatches: fingerprintMatches, candidates: plausible),
                artistAgreement: agreementCount(for: .artist, fingerprintMatches: fingerprintMatches, candidates: plausible),
                durationCorroborated: durationCorroborated(plausible, fileDuration: track.duration)
            ),
            identitySummary: identitySummary(
                track: track,
                fingerprint: bestFingerprint,
                sources: contributingSources,
                rejectedForLength: rejectedForLength
            ),
            fields: verifications,
            artwork: artworkProposal(
                from: plausible,
                matchingAlbum: agreedAlbum(in: verifications, track: track),
                fileHasArtwork: fileHasArtwork
            )
        )
    }

    /// The album this track is being said to belong to — the proposed value
    /// when the album is being corrected, otherwise what is already there.
    static func agreedAlbum(in verifications: [TagFieldVerification], track: Track) -> String {
        guard let album = verifications.first(where: { $0.field == .album }) else { return track.album }
        return album.isChange ? album.proposedValue : track.album
    }

    /// How many distinct sources back the winning value for one field.
    static func agreementCount(
        for field: TagIntegrityAudit.Field,
        fingerprintMatches: [AudioFingerprintSuggestion],
        candidates: [OnlineTrackMetadataCandidate]
    ) -> Int {
        let fieldClaims = claims(
            for: field,
            fingerprintMatches: fingerprintMatches,
            candidates: candidates
        )
        return winningValue(from: fieldClaims)?.sources.count ?? 0
    }

    /// True when at least one source that actually reported a length matched
    /// the file's. Candidates with no length are not evidence either way.
    static func durationCorroborated(
        _ candidates: [OnlineTrackMetadataCandidate],
        fileDuration: TimeInterval?,
        tolerance: Double = 12
    ) -> Bool {
        guard let fileDuration, fileDuration > 0 else { return false }
        return candidates.contains { candidate in
            guard let length = candidate.durationSeconds, length > 0 else { return false }
            return abs(length - fileDuration) <= tolerance
        }
    }

    /// Picks the cover art to offer.
    ///
    /// Art must belong to the release the other fields settled on. Picking
    /// purely by image size attached the cover of a remixes EP to a track whose
    /// album consensus was a different record — observed against the live APIs,
    /// and exactly the kind of quietly-wrong result this whole design exists to
    /// avoid. So candidates matching the agreed album are considered first, and
    /// only if none has art does it fall back to any plausible candidate.
    ///
    /// Within each group the order is by image size rather than the
    /// source-authority order used for text: every candidate already survived
    /// the same filters, so what differs is resolution. Deezer serves 1000px,
    /// iTunes 600px after the URL is upscaled, MusicBrainz whatever the Cover
    /// Art Archive holds. Embedded art gets looked at on phones and
    /// controllers, so bigger wins.
    static func artworkProposal(
        from candidates: [OnlineTrackMetadataCandidate],
        matchingAlbum album: String,
        fileHasArtwork: Bool
    ) -> ArtworkProposal? {
        let preference: [OnlineMetadataSource] = [.deezer, .itunes, .musicBrainz, .discogs]
        let normalizedAlbum = TagIntegrityAudit.normalize(album)

        let onAlbum = normalizedAlbum.isEmpty
            ? []
            : candidates.filter { TagIntegrityAudit.normalize($0.album) == normalizedAlbum }

        for group in [onAlbum, candidates] {
            for source in preference {
                guard let match = group.first(where: { $0.source == source && $0.artworkURL != nil }),
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

        let resolved: (value: String, sources: Set<String>)?
        if field == .year {
            resolved = yearConsensus(
                from: claims,
                preferOriginalRelease: shouldUseOriginalReleaseYear(
                    for: track,
                    fingerprintMatches: fingerprintMatches,
                    candidates: candidates
                )
            )
        } else {
            resolved = winningValue(from: claims)
        }
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

    /// Whether this track's year should be the original song's rather than
    /// this version's.
    ///
    /// True for a remix or edit outside electronic music. A hip-hop or rock
    /// record remixed years later is still that record and is tagged with the
    /// year the song came out; in electronic music a remix is a release in its
    /// own right and carries its own date.
    static func shouldUseOriginalReleaseYear(
        for track: Track,
        fingerprintMatches: [AudioFingerprintSuggestion],
        candidates: [OnlineTrackMetadataCandidate]
    ) -> Bool {
        guard isVersionOfAnotherRecording(track.title) else { return false }
        return !GenreCanonicalizer.isElectronic(effectiveGenre(
            for: track,
            fingerprintMatches: fingerprintMatches,
            candidates: candidates
        ))
    }

    /// The genre to reason about: what the track already has, or failing that
    /// what the sources agree on. A track with no genre yet still needs the
    /// year rule applied.
    static func effectiveGenre(
        for track: Track,
        fingerprintMatches: [AudioFingerprintSuggestion],
        candidates: [OnlineTrackMetadataCandidate]
    ) -> String {
        let current = track.genre.trimmingCharacters(in: .whitespacesAndNewlines)
        if !current.isEmpty { return current }

        let genreClaims = claims(
            for: .genre,
            fingerprintMatches: fingerprintMatches,
            candidates: candidates
        )
        return winningValue(from: genreClaims)?.value ?? ""
    }

    /// True when the title marks this as a remix, edit, or other version of a
    /// recording that exists in its own right.
    static func isVersionOfAnotherRecording(_ title: String) -> Bool {
        let lowered = title.lowercased()
        // Only inside brackets or after a dash: a song genuinely called
        // "Remix Culture" is not a remix.
        let markers = ["remix", "edit", "rework", "refix", "flip", "bootleg",
                       "mashup", "mix", "version", "vip", "dub"]
        guard let range = lowered.range(of: #"[\(\[][^\)\]]*[\)\]]|\s-\s.*$"#, options: .regularExpression) else {
            return false
        }
        let descriptor = String(lowered[range])
        return markers.contains { descriptor.contains($0) }
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

        // Genres are canonicalised before they are counted, not just before
        // they are written: iTunes' "Hip-Hop/Rap" and Deezer's "Rap/Hip Hop"
        // are the same answer, and left as written they look like two sources
        // disagreeing rather than two agreeing.
        if field == .genre {
            claims = claims.map {
                Claim(
                    sourceName: $0.sourceName,
                    value: GenreCanonicalizer.canonical($0.value),
                    isFingerprint: $0.isFingerprint
                )
            }
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
    ///
    /// - Parameter preferOriginalRelease: Takes the earliest year any source
    ///   reports rather than the best-supported one. This is the rule for a
    ///   remix or edit outside electronic music: a hip-hop record remixed years
    ///   later is still that record, and its year is the year the song came
    ///   out. Electronic music works the other way — a remix there is its own
    ///   release with its own date — so this stays off for those.
    static func yearConsensus(
        from claims: [Claim],
        tolerance: Int = 1,
        preferOriginalRelease: Bool = false
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

        if preferOriginalRelease, let earliest = parsed.map(\.year).min() {
            // Everything within tolerance of the earliest year is backing the
            // same original release, so they all count as corroborating it.
            let backers = Set(parsed.filter { $0.year - earliest <= tolerance }.map(\.source))
            return (String(earliest), backers)
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

    /// How sure we are that this is the right recording.
    ///
    /// This used to count how many sources *answered*, which is not what
    /// identity means — three sources returning three different songs is not
    /// three-fold confidence. It now rests on how many independently agreed on
    /// the two fields that identify a recording, title and artist, and whether
    /// a source that reported a length matched the file's.
    ///
    /// The distinction stopped being academic when the default source set
    /// shrank to two: the old scale returned 0.65 for two sources, just under
    /// the 0.7 floor for trusting a verdict, so every bulk apply was silently
    /// refused no matter how well the sources agreed.
    static func identityConfidence(
        fingerprint: AudioFingerprintSuggestion?,
        titleAgreement: Int,
        artistAgreement: Int,
        durationCorroborated: Bool
    ) -> Double {
        // A fingerprint identifies the audio itself, so it dominates.
        if let score = fingerprint?.confidence, score > 0 {
            return min(0.97, score)
        }

        // Both fields have to be corroborated; a title everyone agrees on is
        // worth little if they disagree about who made it.
        let corroborated = min(titleAgreement, artistAgreement)
        let base: Double
        switch corroborated {
        case 0:
            base = 0.3
        case 1:
            base = 0.55
        case 2:
            base = 0.78
        default:
            base = 0.88
        }

        return min(0.95, durationCorroborated ? base + 0.05 : base)
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
