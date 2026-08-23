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
        self.proposedValue = proposedValue
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
    public let inputTokens: Int
    public let outputTokens: Int

    public init(inputTokens: Int, outputTokens: Int) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
    }
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
        artwork: ArtworkProposal? = nil
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
                update.title = OnlineTrackMetadataLookupService.titlePreservingDescriptors(
                    from: value,
                    original: track.title
                )
            case .artist:
                update.artist = value
            case .album:
                update.album = value
            case .genre:
                update.genre = value
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
