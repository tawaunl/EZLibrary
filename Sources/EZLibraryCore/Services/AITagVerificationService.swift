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

/// Verifies a track's tags against outside evidence, using Claude with web
/// search as the adjudicator.
///
/// The existing online lookup answers "what does iTunes think this is?" and
/// applies the top hit. That is fine for a chart single and wrong often enough
/// on everything else — a DJ library is full of extended mixes, edits,
/// bootlegs, and white labels, and the top hit for those is usually the
/// original commercial release, which is a different recording.
///
/// This asks a harder question: given the audio fingerprint, the filename, the
/// current tags, and every candidate the structured sources returned, is each
/// field actually right for *this* recording — and if not, what does a source
/// say it should be? Web search is what covers the ground the databases do not:
/// bootlegs, remix credits, and release years that only exist on a label page,
/// a Bandcamp listing, or a forum post.
///
/// Nothing here writes. It returns proposals with a confidence and a source, and
/// the caller decides what to apply.
public enum AITagVerificationService {
    /// The fields this service verifies. `comment` is deliberately excluded —
    /// it is the DJ's own scratch space, not a fact about the recording.
    public static let verifiableFields: [TagIntegrityAudit.Field] = [
        .title, .artist, .album, .genre, .year
    ]

    // These are the shared verification types every engine produces. They are
    // aliased rather than re-declared so existing call sites keep working while
    // the consensus and on-device engines return the same shapes.
    public typealias Verdict = TagVerdict
    public typealias FieldVerification = TagFieldVerification
    public typealias TrackVerification = TrackTagVerification

    public static let engineName = "Claude"
    public static let providerDefaultsKey = "SeratoToolsLLMProvider"

    /// Which cloud model service to call.
    ///
    /// Anthropic is native because it is the only one of the two that offers a
    /// server-side web search, which is the whole reason to reach for a cloud
    /// model over the free tiers. Everything else is reached through the
    /// OpenAI-compatible wire format, which nearly every provider — and every
    /// local runner — speaks.
    public enum Provider: String, CaseIterable, Sendable {
        case anthropic
        case openAICompatible

        public var displayName: String {
            switch self {
            case .anthropic:
                return "Anthropic (Claude)"
            case .openAICompatible:
                return "OpenAI-compatible (OpenAI, OpenRouter, Groq, Ollama, …)"
            }
        }

        /// Whether the provider can search the web itself.
        public var supportsWebSearch: Bool {
            self == .anthropic
        }
    }

    public static func selectedProvider(userDefaults: UserDefaults = .standard) -> Provider {
        guard let raw = userDefaults.string(forKey: providerDefaultsKey),
              let provider = Provider(rawValue: raw) else {
            return .anthropic
        }
        return provider
    }

    /// True when the selected provider has everything it needs to run.
    public static func isConfigured(userDefaults: UserDefaults = .standard) -> Bool {
        switch selectedProvider(userDefaults: userDefaults) {
        case .anthropic:
            return ClaudeAPIClient.hasAPIKey(userDefaults: userDefaults)
        case .openAICompatible:
            return OpenAICompatibleClient.configuration(userDefaults: userDefaults) != nil
        }
    }

    public struct Options: Sendable {
        public var provider: Provider
        public var model: ClaudeModel
        /// Lets the model search the web. Off makes runs cheaper and much less
        /// useful — the structured sources alone are what the existing lookup
        /// already does.
        public var useWebSearch: Bool
        /// Include AcoustID fingerprint matches. Needs an AcoustID key and
        /// `fpcalc`; skipped silently when either is missing.
        public var useFingerprint: Bool
        /// Include iTunes/MusicBrainz/Discogs candidates as evidence.
        public var useOnlineCandidates: Bool
        /// Proposals below this confidence are returned but not pre-selected
        /// in the review UI.
        public var minimumConfidence: Double
        /// How many tracks are verified at once. Kept low by default: each one
        /// is a long, search-heavy request, and Anthropic rate limits per key.
        public var maxConcurrentTracks: Int
        public var effort: String?

        public init(
            provider: Provider = .anthropic,
            model: ClaudeModel = .opus5,
            useWebSearch: Bool = true,
            useFingerprint: Bool = true,
            useOnlineCandidates: Bool = true,
            minimumConfidence: Double = 0.75,
            maxConcurrentTracks: Int = 3,
            effort: String? = "high"
        ) {
            self.provider = provider
            self.model = model
            self.useWebSearch = useWebSearch
            self.useFingerprint = useFingerprint
            self.useOnlineCandidates = useOnlineCandidates
            self.minimumConfidence = minimumConfidence
            self.maxConcurrentTracks = maxConcurrentTracks
            self.effort = effort
        }
    }

    public typealias Event = TagVerificationEvent

    // MARK: - Cost estimation

    /// Rough per-track token usage, used only for the "about $X" line shown
    /// before a run starts.
    ///
    /// Input dominates and is dominated in turn by web search results being
    /// pulled into context, which is why the searching and non-searching
    /// estimates differ by so much. These are deliberately generous: an
    /// estimate that comes in under the real bill is worse than useless.
    static let estimatedInputTokensWithSearch = 14000
    static let estimatedInputTokensWithoutSearch = 3000
    static let estimatedOutputTokens = 900

    /// Approximate token cost in USD for verifying `trackCount` tracks.
    /// Excludes Anthropic's per-search web search fee, which is billed
    /// separately from tokens.
    public static func estimatedCost(trackCount: Int, options: Options) -> Double {
        let inputTokens = options.useWebSearch
            ? estimatedInputTokensWithSearch
            : estimatedInputTokensWithoutSearch
        let inputCost = Double(trackCount * inputTokens) / 1_000_000 * options.model.inputCostPerMillionTokens
        let outputCost = Double(trackCount * estimatedOutputTokens) / 1_000_000 * options.model.outputCostPerMillionTokens
        return inputCost + outputCost
    }

    public static func estimatedCostText(trackCount: Int, options: Options) -> String {
        let cost = estimatedCost(trackCount: trackCount, options: options)
        let rounded = cost < 0.01 ? "<$0.01" : String(format: "$%.2f", cost)
        let suffix = options.useWebSearch ? ", plus Anthropic's web search fee" : ""
        return "about \(rounded) in Claude tokens\(suffix)"
    }

    // MARK: - Running

    /// Verifies each track and yields results as they land.
    ///
    /// Tracks are independent, so one failure (a rate limit, an unreadable
    /// file) is reported against that track and the run continues.
    public static func verify(
        tracks: [Track],
        options: Options = Options(),
        apiKey: String? = nil,
        session: URLSession = ClaudeAPIClient.defaultSession
    ) -> AsyncStream<Event> {
        AsyncStream { continuation in
            let task = Task {
                guard !tracks.isEmpty else {
                    continuation.yield(.finished(verified: 0, failed: 0))
                    continuation.finish()
                    return
                }

                let key: String?
                switch options.provider {
                case .anthropic:
                    guard let resolved = apiKey ?? ClaudeAPIClient.apiKey() else {
                        continuation.yield(.aborted(
                            message: ClaudeAPIClient.ClientError.missingAPIKey.localizedDescription
                        ))
                        continuation.finish()
                        return
                    }
                    key = resolved
                case .openAICompatible:
                    guard OpenAICompatibleClient.configuration() != nil else {
                        continuation.yield(.aborted(
                            message: "Set the API base URL, model name, and key for your provider in Settings → API Keys."
                        ))
                        continuation.finish()
                        return
                    }
                    key = nil
                }

                continuation.yield(.started(total: tracks.count))

                var verified = 0
                var failed = 0
                var iterator = tracks.makeIterator()
                let parallelism = max(1, min(options.maxConcurrentTracks, tracks.count))

                await withTaskGroup(of: (Track, Result<TrackVerification, Error>).self) { group in
                    func addNext() {
                        guard let track = iterator.next() else { return }
                        group.addTask {
                            do {
                                let result = try await verify(
                                    track: track,
                                    options: options,
                                    apiKey: key,
                                    session: session
                                )
                                return (track, .success(result))
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

    /// Verifies a single track: gathers evidence, asks the model, parses the
    /// verdicts.
    public static func verify(
        track: Track,
        options: Options = Options(),
        apiKey: String? = nil,
        session: URLSession = ClaudeAPIClient.defaultSession
    ) async throws -> TrackVerification {
        let evidence = await gatherEvidence(for: track, options: options)

        switch options.provider {
        case .anthropic:
            let request = ClaudeAPIClient.Request(
                model: options.model,
                system: systemPrompt,
                userMessage: evidence,
                jsonSchema: responseSchema,
                enableWebSearch: options.useWebSearch,
                maxWebSearches: 6,
                maxTokens: 8000,
                effort: options.effort
            )

            let response = try await ClaudeAPIClient.send(request, apiKey: apiKey, session: session)
            return try parse(
                text: response.text,
                for: track,
                provenance: Provenance(
                    engineLabel: "\(engineName) (\(options.model.displayName))",
                    sourceURLs: response.sourceURLs.compactMap(URL.init(string:)),
                    webSearchCount: response.webSearchCount,
                    usage: TagVerificationUsage(
                        inputTokens: response.usage.inputTokens,
                        outputTokens: response.usage.outputTokens
                    )
                )
            )

        case .openAICompatible:
            guard let configuration = OpenAICompatibleClient.configuration() else {
                throw OpenAICompatibleClient.ClientError.missingConfiguration("The model name")
            }
            let response = try await OpenAICompatibleClient.send(
                system: systemPrompt + "\n\n" + jsonOnlyInstruction,
                user: evidence,
                configuration: configuration,
                session: session
            )
            return try parse(
                text: response.text,
                for: track,
                provenance: Provenance(engineLabel: configuration.model, usage: response.usage)
            )
        }
    }

    // MARK: - Evidence

    /// Assembles everything known about the file into the prompt body.
    ///
    /// Every outside source here is best-effort: a throttled iTunes or a
    /// missing `fpcalc` weakens the evidence but must not fail the run, because
    /// web search can still answer the question on its own.
    static func gatherEvidence(for track: Track, options: Options) async -> String {
        var lines: [String] = []

        // Listed last-ish and labelled as a hint: the model reproduces the shape
        // of whatever looks most like an answer, and a filename shaped
        // "Artist - Title" is exactly that. It has to be present for the cases
        // where the tags are empty, but it must not read as authoritative.
        lines.append("FILE NAME (weak hint only, never copy into a field): \(track.fileURL.lastPathComponent)")
        if let duration = track.duration, duration > 0 {
            let minutes = Int(duration) / 60
            let seconds = Int(duration) % 60
            lines.append("DURATION: \(minutes):\(String(format: "%02d", seconds))")
        }

        // Read once: these are both the search terms and the thing being judged.
        let fileTags = await AudioFileTagReader.readTags(from: track.fileURL)

        lines.append("")
        lines.append("CURRENT TAGS:")
        lines.append("  title: \(displayValue(track.title))")
        lines.append("  artist: \(displayValue(track.artist))")
        lines.append("  album: \(displayValue(track.album))")
        lines.append("  genre: \(displayValue(track.genre))")
        lines.append("  year: \(track.year.map(String.init) ?? "(empty)")")
        if let bpm = track.bpm, bpm > 0 {
            lines.append("  bpm: \(String(format: "%.1f", bpm))")
        }
        if let key = track.key, !key.isEmpty {
            lines.append("  key: \(key)")
        }
        if !track.comment.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("  comment: \(track.comment)")
        }
        if !track.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            lines.append("  label: \(track.label)")
        }

        if !fileTags.isEmpty {
            var fileLines: [String] = []
            if let value = fileTags.title, !TagIntegrityAudit.looselyMatches(value, track.title) {
                fileLines.append("  title: \(value)")
            }
            if let value = fileTags.artist, !TagIntegrityAudit.looselyMatches(value, track.artist) {
                fileLines.append("  artist: \(value)")
            }
            if let value = fileTags.album, !TagIntegrityAudit.looselyMatches(value, track.album) {
                fileLines.append("  album: \(value)")
            }
            if let value = fileTags.year, value != track.year {
                fileLines.append("  year: \(value)")
            }
            if !fileLines.isEmpty {
                lines.append("")
                lines.append("THE AUDIO FILE'S OWN TAGS DISAGREE WITH THE LIBRARY:")
                lines.append(contentsOf: fileLines)
            }
        }

        let auditIssues = TagIntegrityAudit.audit(track)
        if !auditIssues.isEmpty {
            lines.append("")
            lines.append("AUTOMATED CHECKS FLAGGED:")
            for issue in auditIssues {
                lines.append("  - \(issue.summary)")
            }
        }

        if options.useFingerprint {
            let suggestions = (try? await AudioFingerprintService.suggestMetadata(for: track, maxResults: 3)) ?? []
            if !suggestions.isEmpty {
                lines.append("")
                lines.append("ACOUSTID FINGERPRINT MATCHES (identifies the actual audio):")
                for suggestion in suggestions {
                    let confidence = suggestion.confidence.map { String(format: " [match %.0f%%]", $0 * 100) } ?? ""
                    let summary = describe(
                        title: suggestion.title,
                        artist: suggestion.artist,
                        album: suggestion.album,
                        genre: suggestion.genre,
                        year: suggestion.year
                    )
                    lines.append("  - \(summary)\(confidence)")
                }
            }
        }

        if options.useOnlineCandidates {
            // Same rule as the consensus engine: search the file's own tags.
            let query = TagConsensusService.searchQuery(for: track, fileTags: fileTags)
            let candidates = (try? await OnlineTrackMetadataLookupService.lookup(
                query: query,
                maxResultsPerSource: 6,
                deduplicate: false
            )) ?? []
            if !candidates.isEmpty {
                lines.append("")
                lines.append("DATABASE CANDIDATES:")
                for candidate in candidates.prefix(12) {
                    let summary = describe(
                        title: candidate.title,
                        artist: candidate.artist,
                        album: candidate.album,
                        genre: candidate.genre,
                        year: candidate.year
                    )
                    lines.append("  - [\(candidate.source.displayName)] \(summary)")
                }
            }
        }

        lines.append("")
        lines.append("VERIFY THESE FIELDS: \(verifiableFields.map(\.rawValue).joined(separator: ", "))")

        return lines.joined(separator: "\n")
    }

    private static func displayValue(_ value: String) -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "(empty)" : value
    }

    private static func describe(
        title: String,
        artist: String,
        album: String,
        genre: String,
        year: Int?
    ) -> String {
        var parts: [String] = []
        parts.append("\(artist.isEmpty ? "?" : artist) — \(title.isEmpty ? "?" : title)")
        if !album.isEmpty {
            parts.append("album: \(album)")
        }
        if !genre.isEmpty {
            parts.append("genre: \(genre)")
        }
        if let year {
            parts.append("year: \(year)")
        }
        return parts.joined(separator: " | ")
    }

    // MARK: - Prompt

    static let systemPrompt = """
    You verify music metadata for a DJ's Serato library. For one audio file you are given its \
    current tags, its filename, and whatever candidate matches the audio fingerprint service and \
    the music databases returned. Decide, field by field, whether the current tag is correct for \
    the recording actually in that file, and when it is wrong, what the correct value is.

    How to weigh evidence:
    - An AcoustID fingerprint match identifies the actual audio. It is the strongest evidence of \
    which recording this is, and it outranks the tags and the filename.
    - Judge from the ID3 tags, not the file name. The file name is shown only as a weak hint for \
    when the tags are empty or obviously junk; never prefer it to a tag that has a real value, and \
    never copy it into a field.
    - Database candidates (iTunes, MusicBrainz, Discogs) are reliable for commercial releases and \
    unreliable for edits, bootlegs, mashups, and white labels.
    - Search the web when the candidates disagree, when they are missing, or when the track looks \
    like a remix, edit, bootleg, or mashup. Those are common in DJ libraries and frequently absent \
    from the commercial databases, and a label page, Bandcamp listing, or discography page is often \
    the only source that has them right.

    Rules:
    - Keep the version descriptor, exactly as written. "Extended Mix", "Radio Edit", "Dirty", \
    "Clean", "Acapella", "Intro", "(Rampa Remix)" and the like identify which cut of the record \
    this DJ owns. They are part of the title. Never strip one, never reword one, and never replace \
    a specific version's metadata with the original release's.
    - Genre spelling is fixed for one case: any form of hip hop — "Hip-Hop/Rap", "Rap/Hip Hop", \
    "hip hop", "rap" — must be written exactly "Hip Hop".
    - Year for a remix or edit depends on the genre. Outside electronic music, use the year the \
    original song came out, not the year the remix was released: a hip-hop or rock record remixed \
    later is still that record. In electronic music (house, techno, drum & bass, trance, dance and \
    the like) a remix is its own release, so use the remix's own year.
    - The artist field holds the credited performing artists. Do not move a remixer there unless the \
    release credits them there.
    - Never invent a value. If the evidence does not settle a field, return verdict "unverified" and \
    leave proposed_value empty. An empty tag you cannot fill is "unverified", not "incorrect".
    - Return verdict "incorrect" only when a specific source contradicts the current value. Cite that \
    source in source_url.
    - A pure capitalization or punctuation difference is worth correcting only when the current value \
    is clearly malformed, such as ALL CAPS or missing spaces.
    - Genre should be an actual genre, at roughly the specificity the library already uses.
    - Year is the release year of this specific version, not of the original song when they differ.
    - confidence is your own 0-1 probability that the verdict is right. Be honest and use the low end: \
    a wrong tag written confidently is worse for this library than an unverified one.
    - identity_confidence is how sure you are that you identified the correct recording at all.
    """

    /// The response shape. Deliberately free of numeric bounds and string
    /// length limits — structured outputs reject those constraints.
    static var responseSchema: [String: Any] {
        [
            "type": "object",
            "properties": [
                "identity_confidence": [
                    "type": "number",
                    "description": "0-1 confidence that you identified the correct recording."
                ],
                "identity_summary": [
                    "type": "string",
                    "description": "One sentence naming the recording you believe this file is."
                ],
                "fields": [
                    "type": "array",
                    "description": "One entry per field you were asked to verify.",
                    "items": [
                        "type": "object",
                        "properties": [
                            "field": [
                                "type": "string",
                                "enum": verifiableFields.map(\.rawValue)
                            ],
                            "verdict": [
                                "type": "string",
                                "enum": ["correct", "incorrect", "unverified"]
                            ],
                            "proposed_value": [
                                "type": "string",
                                "description": "The corrected value. Empty unless verdict is 'incorrect'."
                            ],
                            "confidence": [
                                "type": "number",
                                "description": "0-1 confidence in this verdict."
                            ],
                            "evidence": [
                                "type": "string",
                                "description": "One sentence on what this verdict rests on."
                            ],
                            "source_url": [
                                "type": "string",
                                "description": "URL of the source that settles it, or empty."
                            ]
                        ],
                        "required": ["field", "verdict", "proposed_value", "confidence", "evidence", "source_url"],
                        "additionalProperties": false
                    ]
                ]
            ],
            "required": ["identity_confidence", "identity_summary", "fields"],
            "additionalProperties": false
        ]
    }

    // MARK: - Parsing

    /// Instruction appended for providers that have no schema-constrained
    /// output mode. Anthropic's `output_config.format` guarantees the shape;
    /// everywhere else the prompt has to ask for it, and the parser has to
    /// cope when the model wraps it in prose anyway.
    static let jsonOnlyInstruction = """
    Reply with a single JSON object and nothing else — no prose, no code fences. Use exactly \
    this shape:
    {"identity_confidence": 0.0, "identity_summary": "", "fields": [
      {"field": "title|artist|album|genre|year", "verdict": "correct|incorrect|unverified", \
    "proposed_value": "", "confidence": 0.0, "evidence": "", "source_url": ""}
    ]}
    """

    /// Where a verdict came from, kept together so the parser signature stays
    /// about the verdict rather than about bookkeeping.
    struct Provenance {
        let engineLabel: String
        var sourceURLs: [URL] = []
        var webSearchCount: Int = 0
        var usage: TagVerificationUsage?
    }

    static func parse(
        text: String,
        for track: Track,
        provenance: Provenance
    ) throws -> TrackVerification {
        guard let payload = jsonObject(from: text) else {
            throw ClaudeAPIClient.ClientError.invalidResponse("the verdict was not valid JSON")
        }

        let rawFields = (payload["fields"] as? [[String: Any]]) ?? []
        var verifications: [FieldVerification] = []

        for raw in rawFields {
            guard let fieldName = raw["field"] as? String,
                  let field = TagIntegrityAudit.Field(rawValue: fieldName),
                  let verdictName = raw["verdict"] as? String,
                  let verdict = Verdict(rawValue: verdictName) else {
                continue
            }

            let proposed = (raw["proposed_value"] as? String) ?? ""
            let sourceText = (raw["source_url"] as? String) ?? ""
            verifications.append(FieldVerification(
                field: field,
                verdict: verdict,
                currentValue: currentValue(of: field, in: track),
                proposedValue: proposed,
                confidence: doubleValue(raw["confidence"]),
                evidence: (raw["evidence"] as? String) ?? "",
                sourceURL: sourceText.hasPrefix("http") ? URL(string: sourceText) : nil
            ))
        }

        return TrackVerification(
            track: track,
            engineName: provenance.engineLabel,
            identityConfidence: doubleValue(payload["identity_confidence"]),
            identitySummary: (payload["identity_summary"] as? String) ?? "",
            fields: verifications,
            sourceURLs: provenance.sourceURLs,
            webSearchCount: provenance.webSearchCount,
            usage: provenance.usage
        )
    }

    static func currentValue(of field: TagIntegrityAudit.Field, in track: Track) -> String {
        switch field {
        case .title:
            return track.title
        case .artist:
            return track.artist
        case .album:
            return track.album
        case .genre:
            return track.genre
        case .year:
            return track.year.map(String.init) ?? ""
        case .comment:
            return track.comment
        }
    }

    private static func doubleValue(_ raw: Any?) -> Double {
        if let value = raw as? Double { return value }
        if let value = raw as? Int { return Double(value) }
        if let value = raw as? String, let parsed = Double(value) { return parsed }
        return 0
    }

    /// Parses the reply as JSON, falling back to the outermost `{...}` in the
    /// text. The schema normally guarantees a bare JSON body, but the fallback
    /// covers the path where the API declined the schema and the model answered
    /// in prose around it.
    static func jsonObject(from text: String) -> [String: Any]? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let data = trimmed.data(using: .utf8),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            return object
        }

        guard let end = trimmed.lastIndex(of: "}") else { return nil }

        // Try each opening brace in turn rather than only the first. Preamble
        // prose can contain a brace of its own, and anchoring on it would make
        // the whole slice unparseable even though the real object is right
        // there after it.
        var searchStart = trimmed.startIndex
        while let start = trimmed[searchStart...].firstIndex(of: "{"), start < end {
            let slice = String(trimmed[start...end])
            if let data = slice.data(using: .utf8),
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                return object
            }
            searchStart = trimmed.index(after: start)
        }

        return nil
    }
}
