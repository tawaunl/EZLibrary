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

/// The shared result shape for every tag verifier.
///
/// Three engines produce these — free multi-source consensus, Apple's
/// on-device model, and a bring-your-own-key cloud model — and the review UI
/// treats them identically. What differs between engines is how a verdict was
/// reached, not what a verdict *is*, so the reasoning is carried as text and
/// sources rather than as engine-specific structure.
public enum TagVerdict: String, Sendable, Hashable {
    /// The evidence supports the current value.
    case correct
    /// A source contradicts the current value.
    case incorrect
    /// Not enough evidence either way. Never a reason to change anything.
    case unverified
}

public struct TagFieldVerification: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let field: TagIntegrityAudit.Field
    public let verdict: TagVerdict
    public let currentValue: String
    /// Empty unless `verdict == .incorrect`.
    public let proposedValue: String
    /// 0–1 confidence in this verdict.
    public let confidence: Double
    /// One sentence on what the verdict rests on.
    public let evidence: String
    public let sourceURL: URL?

    public init(
        id: UUID = UUID(),
        field: TagIntegrityAudit.Field,
        verdict: TagVerdict,
        currentValue: String,
        proposedValue: String,
        confidence: Double,
        evidence: String,
        sourceURL: URL? = nil
    ) {
        self.id = id
        self.field = field
        self.verdict = verdict
        self.currentValue = currentValue
        // A genre is proposed as it will be written: "Hip-Hop/Rap" shows as
        // "Hip Hop", and is then no change at all for a track already tagged
        // "Hip Hop".
        self.proposedValue = field == .genre ? GenreCanonicalizer.forWriting(proposedValue) : proposedValue
        self.confidence = confidence
        self.evidence = evidence
        self.sourceURL = sourceURL
    }

    /// True when applying this would actually change the stored value.
    public var isChange: Bool {
        guard verdict == .incorrect else { return false }
        let proposed = proposedValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !proposed.isEmpty else { return false }
        return proposed != currentValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// Token spend for one verification, when the engine bills by tokens.
public struct TagVerificationUsage: Sendable, Equatable {
    /// Uncached input. Anthropic reports cached tokens separately, so this
    /// does not include them.
    public let inputTokens: Int
    public let outputTokens: Int
    /// Input written to the prompt cache, billed at 1.25× the input price.
    public let cacheWriteTokens: Int
    /// Input read back from the prompt cache, billed at the cache-read price.
    public let cacheReadTokens: Int

    public init(inputTokens: Int, outputTokens: Int, cacheWriteTokens: Int = 0, cacheReadTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheWriteTokens = cacheWriteTokens
        self.cacheReadTokens = cacheReadTokens
    }

    public static let zero = TagVerificationUsage(inputTokens: 0, outputTokens: 0)

    public static func + (lhs: TagVerificationUsage, rhs: TagVerificationUsage) -> TagVerificationUsage {
        TagVerificationUsage(
            inputTokens: lhs.inputTokens + rhs.inputTokens,
            outputTokens: lhs.outputTokens + rhs.outputTokens,
            cacheWriteTokens: lhs.cacheWriteTokens + rhs.cacheWriteTokens,
            cacheReadTokens: lhs.cacheReadTokens + rhs.cacheReadTokens
        )
    }

    public static func += (lhs: inout TagVerificationUsage, rhs: TagVerificationUsage) {
        lhs = lhs + rhs
    }

    /// What these tokens cost on `model`, in USD. Web search fees are billed
    /// separately and are not included.
    public func tokenCost(on model: ClaudeModel) -> Double {
        tokenCost(at: model.pricing)
    }

    public func tokenCost(at pricing: ModelPricing) -> Double {
        (Double(inputTokens) * pricing.input
            + Double(cacheWriteTokens) * pricing.cacheWrite
            + Double(cacheReadTokens) * pricing.cacheRead
            + Double(outputTokens) * pricing.output) / 1_000_000
    }
}

/// Where one track's time went, so a slow run can be pinned on the network or
/// on the model instead of guessed at.
public struct TagVerificationTimings: Sendable, Equatable {
    /// Gathering evidence: reading the file's tags and the database lookups.
    public let lookupSeconds: Double
    /// Waiting on the model, across every pass.
    public let modelSeconds: Double
    /// Searches the model itself asked for through a tool, on top of the
    /// up-front lookup. Each one is another lookup *and* another round of
    /// model output.
    public let toolCalls: Int
    /// How many times the model was asked. More than one means the first
    /// attempt failed and was retried in a smaller form.
    public let attempts: Int

    public init(lookupSeconds: Double, modelSeconds: Double, toolCalls: Int = 0, attempts: Int = 1) {
        self.lookupSeconds = lookupSeconds
        self.modelSeconds = modelSeconds
        self.toolCalls = toolCalls
        self.attempts = attempts
    }
}

extension Duration {
    /// Seconds as a Double, for timings that get logged and compared.
    var seconds: Double {
        let parts = components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// A model's published list prices, in USD per million tokens.
///
/// One shape for every provider, so the pre-run estimate, the running spend,
/// and the run log price a Claude run and an OpenAI run the same way.
public struct ModelPricing: Sendable, Equatable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite: Double

    public init(input: Double, output: Double, cacheRead: Double, cacheWrite: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite = cacheWrite
    }

    /// A model running on this Mac: there is no bill.
    public static let free = ModelPricing(input: 0, output: 0, cacheRead: 0, cacheWrite: 0)

    public var isFree: Bool { self == .free }
}

/// Cover art a source offers for a track.
///
/// Artwork is kept out of `TagFieldVerification` because it cannot be judged
/// the way a text field is: two sources "agreeing" on cover art would mean
/// comparing images, and what actually matters is far simpler — whether the
/// file has any art at all, and whether a source has some for the release the
/// other fields already agreed on.
public struct ArtworkProposal: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let sourceName: String
    public let url: URL
    /// True when the file carries no embedded cover art. This is the case worth
    /// acting on; when false, applying would replace art the user may have
    /// chosen deliberately.
    public let fileIsMissingArtwork: Bool
    /// The release this art belongs to, so the user can see it matches.
    public let albumTitle: String

    public init(
        id: UUID = UUID(),
        sourceName: String,
        url: URL,
        fileIsMissingArtwork: Bool,
        albumTitle: String
    ) {
        self.id = id
        self.sourceName = sourceName
        self.url = url
        self.fileIsMissingArtwork = fileIsMissingArtwork
        self.albumTitle = albumTitle
    }
}

public struct TrackTagVerification: Sendable, Identifiable {
    public let track: Track
    /// Which engine produced this, for display.
    public let engineName: String
    /// How sure the engine is that it identified the right recording at all.
    /// A low value makes every field verdict below it suspect, however
    /// confident those individually are.
    public let identityConfidence: Double
    public let identitySummary: String
    public let fields: [TagFieldVerification]
    /// Pages or records the verdict was based on.
    public let sourceURLs: [URL]
    /// Web searches performed, for engines that search.
    public let webSearchCount: Int
    /// Token spend, for engines that bill by tokens. Nil for free engines.
    public let usage: TagVerificationUsage?
    /// Cover art on offer, when a source has some. Nil when no source returned
    /// any.
    public let artwork: ArtworkProposal?
    /// True when a first pass without web search was not sure enough and the
    /// track went round again with search. Recorded so a run can report how
    /// often the cheap pass was enough — the number every cost decision about
    /// this tier turns on.
    public let neededSearchPass: Bool
    /// Nil for engines that do not measure it.
    public let timings: TagVerificationTimings?

    public var id: UUID { track.id }

    public var proposedChanges: [TagFieldVerification] {
        fields.filter(\.isChange)
    }

    public init(
        track: Track,
        engineName: String,
        identityConfidence: Double,
        identitySummary: String,
        fields: [TagFieldVerification],
        sourceURLs: [URL] = [],
        webSearchCount: Int = 0,
        usage: TagVerificationUsage? = nil,
        artwork: ArtworkProposal? = nil,
        neededSearchPass: Bool = false,
        timings: TagVerificationTimings? = nil
    ) {
        self.track = track
        self.engineName = engineName
        self.identityConfidence = identityConfidence
        self.identitySummary = identitySummary
        self.fields = fields
        self.sourceURLs = sourceURLs
        self.webSearchCount = webSearchCount
        self.usage = usage
        self.artwork = artwork
        self.neededSearchPass = neededSearchPass
        self.timings = timings
    }

    /// The same result with timings attached. Engines measure from outside
    /// the code that builds the result, so they add it afterwards.
    public func with(timings: TagVerificationTimings) -> TrackTagVerification {
        TrackTagVerification(
            track: track,
            engineName: engineName,
            identityConfidence: identityConfidence,
            identitySummary: identitySummary,
            fields: fields,
            sourceURLs: sourceURLs,
            webSearchCount: webSearchCount,
            usage: usage,
            artwork: artwork,
            neededSearchPass: neededSearchPass,
            timings: timings
        )
    }

    /// The same result with cover art on offer.
    public func with(artwork: ArtworkProposal?) -> TrackTagVerification {
        TrackTagVerification(
            track: track,
            engineName: engineName,
            identityConfidence: identityConfidence,
            identitySummary: identitySummary,
            fields: fields,
            sourceURLs: sourceURLs,
            webSearchCount: webSearchCount,
            usage: usage,
            artwork: artwork,
            neededSearchPass: neededSearchPass,
            timings: timings
        )
    }

    /// Builds the update that applies exactly the named fields. Every other
    /// field is carried through unchanged, so this can be handed straight to
    /// the existing metadata writer.
    public func metadataUpdate(applying fieldsToApply: Set<TagIntegrityAudit.Field>) -> SeratoTrackMetadataUpdate {
        var update = SeratoTrackMetadataUpdate(
            title: track.title,
            artist: track.artist,
            album: track.album,
            genre: track.genre,
            comment: track.comment,
            key: track.key ?? "",
            bpm: track.bpm,
            year: track.year
        )

        for verification in fields where fieldsToApply.contains(verification.field) && verification.isChange {
            let value = verification.proposedValue.trimmingCharacters(in: .whitespacesAndNewlines)
            switch verification.field {
            case .title:
                // The one place every engine's title correction passes through,
                // and therefore the right place to guarantee the thing that
                // must never break: a DJ owns a specific version of a record,
                // and "(Extended Mix)", "(Dirty)", "(Rampa Remix)" identify it.
                // The databases return the plain song title, so a correction
                // that is right about the song is still destructive if it drops
                // the version. Re-attaching here means no engine — present or
                // future — can lose one, whatever its prompt or its scoring
                // says.
                //
                // The same choke point strips the artist back out: the artist
                // has its own tag and does not belong in the title.
                update.title = OnlineTrackMetadataLookupService.titlePreservingDescriptors(
                    from: OnlineTrackMetadataLookupService.titleWithoutArtist(value, artist: track.artist),
                    original: track.title
                )
            case .artist:
                update.artist = value
            case .album:
                update.album = value
            case .genre:
                // Same choke point as the title, for the same reason: the
                // sources spell one genre three ways ("Hip-Hop/Rap",
                // "Rap/Hip Hop", "hip hop") and writing them through verbatim
                // produces three genres in a library that should have one.
                update.genre = GenreCanonicalizer.canonical(value)
            case .year:
                // A year the engine could not express as a number is not a
                // year; dropping the change beats writing a garbage value.
                if let year = Int(value.prefix(4)), (1900...2100).contains(year) {
                    update.year = year
                }
            case .comment:
                update.comment = value
            }
        }

        return update
    }
}

/// Progress from a verification run, whichever engine is doing the work.
public enum TagVerificationEvent: Sendable {
    case started(total: Int)
    case verified(TrackTagVerification)
    case failed(track: Track, message: String)
    /// The run could not start at all — no credential, no on-device model.
    /// Distinct from per-track failures so the UI can say why once rather than
    /// reporting every track as individually broken.
    case aborted(message: String)
    case finished(verified: Int, failed: Int)
}
