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

public struct AudioFingerprintSuggestion: Sendable, Hashable, Identifiable {
    public let id: UUID
    public let provider: String
    public let title: String
    public let artist: String
    public let album: String
    public let genre: String
    public let year: Int?
    public let confidence: Double?
    public let comment: String

    public init(
        id: UUID = UUID(),
        provider: String,
        title: String,
        artist: String,
        album: String,
        genre: String,
        year: Int?,
        confidence: Double?,
        comment: String = ""
    ) {
        self.id = id
        self.provider = provider
        self.title = title
        self.artist = artist
        self.album = album
        self.genre = genre
        self.year = year
        self.confidence = confidence
        self.comment = comment
    }
}

public enum AudioFingerprintService {
    public static let tokenEnvironmentKey = "EZLIBRARY_ACOUSTID_KEY"
    /// Legacy environment key, still honored for backward compatibility.
    public static let legacyTokenEnvironmentKey = "SERATOTOOLS_ACOUSTID_KEY"
    public static let tokenDefaultsKey = "SeratoToolsAcoustIDKey"
    public static let fpcalcPathEnvironmentKey = "EZLIBRARY_FPCALC_PATH"
    /// Legacy environment key, still honored for backward compatibility.
    public static let legacyFpcalcPathEnvironmentKey = "SERATOTOOLS_FPCALC_PATH"

    public enum FingerprintError: Error, LocalizedError {
        case missingToken
        case fileNotReadable(URL)
        case fpcalcNotInstalled
        case homebrewInstallFailed(String)
        case fpcalcInstallFailed(String)
        case fingerprintExtractionFailed(String)
        case invalidResponse
        case serviceRejected(String)

        public var errorDescription: String? {
            switch self {
            case .missingToken:
                return "Audio fingerprint lookup requires an AcoustID API key. Set EZLIBRARY_ACOUSTID_KEY or save an AcoustID key in API Keys."
            case let .fileNotReadable(url):
                return "Unable to read audio file for fingerprint lookup: \(url.lastPathComponent)"
            case .fpcalcNotInstalled:
                return "Fingerprint scanner dependency not found. Install chromaprint fpcalc to use AcoustID lookup."
            case let .homebrewInstallFailed(message):
                return "Automatic Homebrew installation failed: \(message)"
            case let .fpcalcInstallFailed(message):
                return "Automatic fpcalc installation failed: \(message)"
            case let .fingerprintExtractionFailed(message):
                return "Could not extract an audio fingerprint: \(message)"
            case .invalidResponse:
                return "AcoustID returned an unexpected response format."
            case let .serviceRejected(message):
                return "Fingerprint service rejected the request: \(message)"
            }
        }
    }

    public enum TokenValidationResult: Sendable {
        case valid
        case invalid(String)
    }

    public static func suggestMetadata(
        for track: Track,
        maxResults: Int = 5,
        session: URLSession = .shared
    ) async throws -> [AudioFingerprintSuggestion] {
        guard let tokenInfo = tokenWithSource() else {
            throw FingerprintError.missingToken
        }
        let token = tokenInfo.value

        guard FileManager.default.fileExists(atPath: track.fileURL.path) else {
            throw FingerprintError.fileNotReadable(track.fileURL)
        }

        let extracted = try extractFingerprintWithFpcalc(fileURL: track.fileURL)

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "client", value: token),
            URLQueryItem(name: "duration", value: String(extracted.duration)),
            URLQueryItem(name: "fingerprint", value: extracted.fingerprint),
            URLQueryItem(name: "meta", value: "recordings+releases")
        ]

        var request = URLRequest(url: URL(string: "https://api.acoustid.org/v2/lookup")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("EZLibrary/1.0 (audio fingerprint)", forHTTPHeaderField: "User-Agent")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            let detail = parseHTTPErrorDetail(data: data)
            let normalized = normalizeAcoustIDErrorMessage(detail)
            throw FingerprintError.serviceRejected(
                "HTTP \(http.statusCode): \(normalized) (key source: \(tokenInfo.source), key: \(redactedKeyDebug(token)), fpcalc: \(extracted.fpcalcPath))"
            )
        }

        let parsed = try parseLookupResponseJSON(data)

        if parsed.status.lowercased() != "ok" {
            let code = parsed.errorCode ?? "unknown"
            let message = parsed.errorMessage ?? "Unknown service error"
            let errorText = normalizeAcoustIDErrorMessage(
                "code \(code): \(message) (key source: \(tokenInfo.source), key: \(redactedKeyDebug(token)), fpcalc: \(extracted.fpcalcPath))"
            )
            throw FingerprintError.serviceRejected(errorText)
        }

        let suggestions = parsed.suggestions
        return Array(suggestions.prefix(max(1, maxResults)))
    }

    public static func validateClientKey(
        _ key: String,
        session: URLSession = .shared
    ) async -> TokenValidationResult {
        let token = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .invalid("AcoustID client key is empty.")
        }

        var components = URLComponents()
        components.queryItems = [
            URLQueryItem(name: "format", value: "json"),
            URLQueryItem(name: "client", value: token),
            URLQueryItem(name: "duration", value: "120"),
            URLQueryItem(name: "fingerprint", value: "AQAAO0mUaEkSZSoAAAAAAAAA")
        ]

        var request = URLRequest(url: URL(string: "https://api.acoustid.org/v2/lookup")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("EZLibrary/1.0 (audio fingerprint)", forHTTPHeaderField: "User-Agent")
        request.httpBody = components.percentEncodedQuery?.data(using: .utf8)

        do {
            let (data, response) = try await session.data(for: request)

            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
                let detail = parseHTTPErrorDetail(data: data)
                if isInvalidClientError(detail) {
                    return .invalid("Invalid AcoustID client key.")
                }
                return .invalid("Could not validate key (HTTP \(http.statusCode): \(detail))")
            }

            if let decoded = try? JSONDecoder().decode(AcoustIDLookupResponse.self, from: data) {
                if decoded.status.lowercased() == "ok" {
                    return .valid
                }

                let message = decoded.error?.message ?? "Unknown service error"
                if isInvalidClientError(message) {
                    return .invalid("Invalid AcoustID client key.")
                }

                // The probe intentionally uses an invalid fingerprint.
                // If the only error is fingerprint-related, the client key itself is valid.
                if isInvalidFingerprintError(message, code: decoded.error?.code) {
                    return .valid
                }

                return .invalid("Could not validate key (\(message))")
            }

            return .invalid("Could not validate key (unexpected response format).")
        } catch {
            return .invalid("Could not validate key (network error: \(error.localizedDescription)).")
        }
    }

    private static func parseSuggestion(recording: AcoustIDRecording, score: Double?) -> AudioFingerprintSuggestion? {
        let title = (recording.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let artist = (recording.artists?.first?.name ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let album = (recording.releases?.first?.title ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let genre = ""

        guard !title.isEmpty || !artist.isEmpty || !album.isEmpty else {
            return nil
        }

        let year = parseYear(from: recording.releases?.first?.date)
        let confidence = score

        return AudioFingerprintSuggestion(
            provider: "AcoustID",
            title: title,
            artist: artist,
            album: album,
            genre: genre,
            year: year,
            confidence: confidence,
            comment: "External fingerprint match via AcoustID"
        )
    }

    private static func parseYear(from releaseDate: String?) -> Int? {
        guard let releaseDate, releaseDate.count >= 4 else { return nil }
        return Int(releaseDate.prefix(4))
    }

    private static func tokenWithSource(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> (value: String, source: String)? {
        if let value = userDefaults.string(forKey: tokenDefaultsKey)?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return (value, "saved key")
        }
        if let value = (environment[tokenEnvironmentKey] ?? environment[legacyTokenEnvironmentKey])?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return (value, "environment")
        }
        return nil
    }

    private static func extractFingerprintWithFpcalc(fileURL: URL) throws -> (duration: Int, fingerprint: String, fpcalcPath: String) {
        var fpcalcPath = resolveFpcalcPath()
        if fpcalcPath == nil {
            try attemptAutoInstallFpcalc()
            fpcalcPath = resolveFpcalcPath()
        }
        guard let fpcalcPath else {
            throw FingerprintError.fpcalcNotInstalled
        }

        // Both streams are drained concurrently before waiting. fpcalc's stderr
        // carries FFmpeg's decoder diagnostics, which on an unusual or slightly
        // damaged file runs long enough to fill the pipe buffer — and a full
        // buffer stops fpcalc mid-write, so it never exits and the lookup hangs
        // forever instead of failing.
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: fpcalcPath),
                arguments: ["-length", "120", fileURL.path]
            )
        } catch {
            throw FingerprintError.fpcalcNotInstalled
        }

        guard result.didSucceed else {
            let errorText = result.errorText
            throw FingerprintError.fingerprintExtractionFailed(errorText.isEmpty ? "fpcalc failed" : errorText)
        }

        let output = result.outputText
        var duration: Int?
        var fingerprint: String?
        for line in output.split(separator: "\n") {
            if line.hasPrefix("DURATION=") {
                duration = Int(line.replacingOccurrences(of: "DURATION=", with: ""))
            } else if line.hasPrefix("FINGERPRINT=") {
                fingerprint = line.replacingOccurrences(of: "FINGERPRINT=", with: "")
            }
        }

        guard let duration, let fingerprint, !fingerprint.isEmpty else {
            throw FingerprintError.fingerprintExtractionFailed("fpcalc did not return duration/fingerprint")
        }

        return (duration, fingerprint, fpcalcPath)
    }

    private static func parseHTTPErrorDetail(data: Data) -> String {
        if let decoded = try? JSONDecoder().decode(AcoustIDLookupResponse.self, from: data),
           let message = decoded.error?.message,
           !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return message
        }

        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let error = json["error"] {
            if let string = error as? String, !string.isEmpty {
                return string
            }
            if let obj = error as? [String: Any],
               let message = obj["message"] as? String,
               !message.isEmpty {
                return message
            }
        }

        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return raw.isEmpty ? "No response details" : raw
    }

    private static func parseLookupResponseJSON(_ data: Data) throws -> ParsedLookupResponse {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw FingerprintError.serviceRejected("AcoustID returned non-JSON data: \(responseSnippet(data))")
        }

        let status = (root["status"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !status.isEmpty else {
            throw FingerprintError.serviceRejected("AcoustID response missing status: \(responseSnippet(data))")
        }

        let errorObject = root["error"] as? [String: Any]
        let errorCode: String?
        if let intCode = errorObject?["code"] as? Int {
            errorCode = String(intCode)
        } else if let stringCode = errorObject?["code"] as? String {
            errorCode = stringCode
        } else {
            errorCode = nil
        }

        let errorMessage = (errorObject?["message"] as? String) ?? (root["error"] as? String)

        let suggestions: [AudioFingerprintSuggestion]
        if status.lowercased() == "ok" {
            suggestions = parseSuggestionsFromResults(root["results"])
        } else {
            suggestions = []
        }

        return ParsedLookupResponse(
            status: status,
            errorCode: errorCode,
            errorMessage: errorMessage,
            suggestions: suggestions
        )
    }

    /// Turns AcoustID's response into ranked, de-duplicated suggestions.
    ///
    /// The raw response is not directly presentable. One fingerprint commonly
    /// maps to a dozen MusicBrainz recordings of the same song — one per
    /// release it ever appeared on — so flattening the response verbatim
    /// produced a list of near-identical rows, and truncating that list to
    /// `maxResults` meant every row came from the *first* match while a genuine
    /// second candidate never appeared at all. This collapses those into one
    /// suggestion per distinct recording, keeps the highest-scoring instance of
    /// each, and orders by score so the best match is first.
    ///
    /// `minimumScore` drops fingerprint matches weak enough to be noise. If
    /// that would discard everything, the single best match is kept anyway —
    /// showing one low-confidence row beats reporting "no match found".
    static func parseSuggestionsFromResults(
        _ value: Any?,
        minimumScore: Double = 0.5
    ) -> [AudioFingerprintSuggestion] {
        guard let results = value as? [[String: Any]] else { return [] }

        // AcoustID usually returns results best-first, but it is not promised,
        // and ranking is the whole point of the score.
        let ranked = results.sorted { lhs, rhs in
            ((lhs["score"] as? Double) ?? 0) > ((rhs["score"] as? Double) ?? 0)
        }

        var byRecording: [String: AudioFingerprintSuggestion] = [:]
        var order: [String] = []

        for result in ranked {
            let score = result["score"] as? Double
            guard let recordings = result["recordings"] as? [[String: Any]] else { continue }

            for recording in recordings {
                let title = trimmedString(recording["title"])
                let artists = recording["artists"] as? [[String: Any]]
                let artist = trimmedString(artists?.first?["name"])
                let album = preferredAlbumTitle(from: recording)
                let year = extractYear(from: recording)

                guard !title.isEmpty || !artist.isEmpty || !album.isEmpty else { continue }

                let key = "\(title.lowercased())|\(artist.lowercased())"
                let suggestion = AudioFingerprintSuggestion(
                    provider: "AcoustID",
                    title: title,
                    artist: artist,
                    album: album,
                    genre: "",
                    year: year,
                    confidence: score,
                    comment: "External fingerprint match via AcoustID"
                )

                if let existing = byRecording[key] {
                    // Same recording seen again under a weaker match; keep the
                    // stronger one, but let it inherit detail the winner lacks.
                    guard (score ?? 0) > (existing.confidence ?? 0) else {
                        if existing.album.isEmpty, !album.isEmpty {
                            byRecording[key] = AudioFingerprintSuggestion(
                                provider: existing.provider,
                                title: existing.title,
                                artist: existing.artist,
                                album: album,
                                genre: existing.genre,
                                year: existing.year ?? year,
                                confidence: existing.confidence,
                                comment: existing.comment
                            )
                        }
                        continue
                    }
                    byRecording[key] = suggestion
                } else {
                    byRecording[key] = suggestion
                    order.append(key)
                }
            }
        }

        let deduplicated = order.compactMap { byRecording[$0] }
            .sorted { ($0.confidence ?? 0) > ($1.confidence ?? 0) }

        let strong = deduplicated.filter { ($0.confidence ?? 0) >= minimumScore }
        if strong.isEmpty, let best = deduplicated.first {
            return [best]
        }
        return strong
    }

    private static func trimmedString(_ value: Any?) -> String {
        ((value as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Picks the release most likely to be the one a DJ means.
    ///
    /// A recording carries every release it appeared on, in no useful order, so
    /// taking the first gave an arbitrary album — often a regional compilation
    /// or a much later greatest-hits set rather than the original. Preferring
    /// the earliest dated release gets the original in the common case.
    private static func preferredAlbumTitle(from recording: [String: Any]) -> String {
        guard let releases = recording["releases"] as? [[String: Any]], !releases.isEmpty else {
            return ""
        }

        let titled = releases.filter { !trimmedString($0["title"]).isEmpty }
        guard !titled.isEmpty else { return "" }

        let dated = titled.compactMap { release -> (year: Int, title: String)? in
            guard let year = parseYearAny(release["year"]) ?? parseYearAny(release["date"]) else { return nil }
            return (year, trimmedString(release["title"]))
        }

        if let earliest = dated.min(by: { $0.year < $1.year }) {
            return earliest.title
        }
        return trimmedString(titled[0]["title"])
    }

    private static func responseSnippet(_ data: Data) -> String {
        let raw = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if raw.isEmpty { return "<empty body>" }
        return String(raw.prefix(240))
    }

    private static func extractYear(from recording: [String: Any]) -> Int? {
        if let directYear = parseYearAny(recording["year"]) {
            return directYear
        }

        if let releases = recording["releases"] as? [[String: Any]] {
            for release in releases {
                if let year = parseYearAny(release["year"]) ?? parseYearAny(release["date"]) {
                    return year
                }
            }
        }

        if let releaseGroups = recording["releasegroups"] as? [[String: Any]] {
            for group in releaseGroups {
                if let year = parseYearAny(group["first-release-date"]) ?? parseYearAny(group["date"]) ?? parseYearAny(group["year"]) {
                    return year
                }
            }
        }

        return nil
    }

    private static func parseYearAny(_ value: Any?) -> Int? {
        if let intValue = value as? Int {
            return intValue > 0 ? intValue : nil
        }
        if let stringValue = value as? String {
            return parseYear(from: stringValue)
        }
        return nil
    }

    private static func normalizeAcoustIDErrorMessage(_ raw: String) -> String {
        if isInvalidClientError(raw) {
            return "Invalid AcoustID client key. Create an application client key at https://acoustid.org/new-application and save that value in API Keys."
        }
        return raw
    }

    private static func isInvalidClientError(_ message: String) -> Bool {
        let lowered = message.lowercased()
        return lowered.contains("invalid") &&
            (lowered.contains("client") || lowered.contains("api key") || lowered.contains("apikey"))
    }

    private static func isInvalidFingerprintError(_ message: String, code: Int?) -> Bool {
        if code == 3 { return true }
        return message.lowercased().contains("invalid fingerprint")
    }

    private static func redactedKeyDebug(_ key: String) -> String {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "empty" }

        let prefixCount = min(3, trimmed.count)
        let suffixCount = min(2, max(0, trimmed.count - prefixCount))
        let prefix = String(trimmed.prefix(prefixCount))
        let suffix = suffixCount > 0 ? String(trimmed.suffix(suffixCount)) : ""
        return "\(prefix)…\(suffix) (len=\(trimmed.count))"
    }

    /// Resolved path to the `fpcalc` executable (from Homebrew's chromaprint),
    /// or nil when it isn't installed. Exposed so the app can report readiness.
    public static func fpcalcExecutablePath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        resolveFpcalcPath(environment: environment, fileManager: fileManager)
    }

    private static func resolveFpcalcPath(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        fileManager: FileManager = .default
    ) -> String? {
        if let override = (environment[fpcalcPathEnvironmentKey] ?? environment[legacyFpcalcPathEnvironmentKey])?.trimmingCharacters(in: .whitespacesAndNewlines),
           !override.isEmpty,
           fileManager.isExecutableFile(atPath: override) {
            return override
        }

        let candidates = [
            "/opt/homebrew/bin/fpcalc",
            "/usr/local/bin/fpcalc",
            "/usr/bin/fpcalc"
        ]

        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }

        return nil
    }

    private static func resolveBrewPath(fileManager: FileManager = .default) -> String? {
        let candidates = [
            "/opt/homebrew/bin/brew",
            "/usr/local/bin/brew"
        ]
        for path in candidates where fileManager.isExecutableFile(atPath: path) {
            return path
        }
        return nil
    }

    private static func attemptAutoInstallFpcalc() throws {
        var brewPath = resolveBrewPath()
        if brewPath == nil {
            try attemptAutoInstallHomebrew()
            brewPath = resolveBrewPath()
        }

        guard let brewPath else {
            throw FingerprintError.homebrewInstallFailed("brew executable was not found after installation attempt")
        }

        // `brew install` writes far more than the pipe buffer holds, so its
        // stdout goes to /dev/null rather than into a pipe nothing reads —
        // that combination hung the installer indefinitely.
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: brewPath),
                arguments: ["install", "chromaprint"],
                environment: [
                    "HOMEBREW_NO_AUTO_UPDATE": "1",
                    "HOMEBREW_NO_ENV_HINTS": "1"
                ],
                standardOutput: .discard
            )
        } catch {
            throw FingerprintError.fpcalcInstallFailed(error.localizedDescription)
        }

        guard result.didSucceed else {
            let err = result.errorText
            throw FingerprintError.fpcalcInstallFailed(err.isEmpty ? "brew install chromaprint failed" : err)
        }
    }

    private static func attemptAutoInstallHomebrew() throws {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/curl") else {
            throw FingerprintError.homebrewInstallFailed("curl is not available")
        }

        // Same reasoning as the brew install above, more so: the Homebrew
        // install script is extremely chatty on stdout.
        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(
                executableURL: URL(fileURLWithPath: "/bin/bash"),
                // Use a non-login shell with an explicit PATH so we never source
                // the user's shell profile. Some machines' profiles invoke
                // `java`/`jenv` (or run `java -version`), which triggers macOS's
                // "No Java runtime present" dialog mid-install even though
                // nothing here needs Java.
                arguments: [
                    "-c",
                    "/bin/bash -c \"$(/usr/bin/curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""
                ],
                environment: [
                    "PATH": "/usr/bin:/bin:/usr/sbin:/sbin",
                    "NONINTERACTIVE": "1",
                    "HOMEBREW_NO_ANALYTICS": "1",
                    "HOME": FileManager.default.homeDirectoryForCurrentUser.path
                ],
                standardOutput: .discard
            )
        } catch {
            throw FingerprintError.homebrewInstallFailed(error.localizedDescription)
        }

        guard result.didSucceed else {
            let err = result.errorText
            throw FingerprintError.homebrewInstallFailed(err.isEmpty ? "Homebrew installer failed" : err)
        }
    }
}

private struct ParsedLookupResponse {
    let status: String
    let errorCode: String?
    let errorMessage: String?
    let suggestions: [AudioFingerprintSuggestion]
}

private struct AcoustIDLookupResponse: Decodable {
    let status: String
    let error: AcoustIDError?
    let results: [AcoustIDResult]?
}

private struct AcoustIDError: Decodable {
    let code: Int?
    let message: String?
}

private struct AcoustIDResult: Decodable {
    let score: Double?
    let recordings: [AcoustIDRecording]?
}

private struct AcoustIDRecording: Decodable {
    let title: String?
    let artists: [AcoustIDArtist]?
    let releases: [AcoustIDRelease]?
}

private struct AcoustIDArtist: Decodable {
    let name: String?
}

private struct AcoustIDRelease: Decodable {
    let title: String?
    let date: String?
}
