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

/// The Claude models this app will talk to, with the per-model capability
/// differences that actually change the request body.
///
/// The API surface is not uniform across models: `effort`, adaptive thinking,
/// server-side refusal fallbacks, and the newer dynamic-filtering web search
/// tool are all rejected outright by models that predate them. Encoding that
/// here — rather than at the call site — keeps a model switch in Settings from
/// turning into a 400 the user has no way to interpret.
public enum ClaudeModel: String, CaseIterable, Sendable {
    case opus5 = "claude-opus-5"
    case sonnet5 = "claude-sonnet-5"
    case haiku45 = "claude-haiku-4-5"

    public var displayName: String {
        switch self {
        case .opus5:
            return "Claude Opus 5 (most accurate)"
        case .sonnet5:
            return "Claude Sonnet 5 (balanced)"
        case .haiku45:
            return "Claude Haiku 4.5 (cheapest)"
        }
    }

    /// Adaptive thinking (`{"type": "adaptive"}`) replaced the old fixed
    /// `budget_tokens` form. Models older than the 4.6 generation reject it.
    var supportsAdaptiveThinking: Bool {
        switch self {
        case .opus5, .sonnet5:
            return true
        case .haiku45:
            return false
        }
    }

    /// `output_config.effort`. Haiku 4.5 errors on it.
    var supportsEffort: Bool {
        switch self {
        case .opus5, .sonnet5:
            return true
        case .haiku45:
            return false
        }
    }

    /// Server-side refusal fallbacks — the API silently re-runs a refused
    /// request on another model inside the same call. Documented for the
    /// Opus 5 / Fable 5 tier only, so it is not sent for anything else.
    var supportsServerSideFallback: Bool {
        switch self {
        case .opus5:
            return true
        case .sonnet5, .haiku45:
            return false
        }
    }

    /// The web search tool version this model accepts. The `_20260209` variant
    /// adds dynamic filtering (the model filters results with code before they
    /// reach its context); models older than the 4.6 generation only take the
    /// original tool.
    var webSearchToolType: String {
        switch self {
        case .opus5, .sonnet5:
            return "web_search_20260209"
        case .haiku45:
            return "web_search_20250305"
        }
    }

    /// Published per-million-token list prices, used only to show the user a
    /// rough cost before a run. Deliberately the standard rates, not
    /// promotional ones, so an estimate is never lower than the real bill.
    public var inputCostPerMillionTokens: Double {
        switch self {
        case .opus5:
            return 5.00
        case .sonnet5:
            return 3.00
        case .haiku45:
            return 1.00
        }
    }

    public var outputCostPerMillionTokens: Double {
        switch self {
        case .opus5:
            return 25.00
        case .sonnet5:
            return 15.00
        case .haiku45:
            return 5.00
        }
    }
}

/// A minimal Claude Messages API client built directly on `URLSession`.
///
/// There is no official Anthropic SDK for Swift, so this speaks the HTTP API
/// directly. It covers only what the tag verifier needs: one non-streaming
/// request, optional server-side web search, a JSON-schema-constrained reply,
/// and the retry/resume rules the API expects around those.
public enum ClaudeAPIClient {
    public static let apiKeyEnvironmentKey = "EZLIBRARY_ANTHROPIC_KEY"
    public static let apiKeyDefaultsKey = "SeratoToolsAnthropicKey"
    public static let modelDefaultsKey = "SeratoToolsAnthropicModel"

    private static let endpoint = URL(string: "https://api.anthropic.com/v1/messages")!
    private static let apiVersion = "2023-06-01"
    private static let serverSideFallbackBeta = "server-side-fallback-2026-07-01"

    /// Web search makes a turn much slower than a plain completion — the model
    /// may run several searches before answering — so this session is far more
    /// patient than the one used for the iTunes/MusicBrainz lookups.
    public static let defaultSession: URLSession = {
        let configuration = URLSessionConfiguration.default
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 300
        configuration.waitsForConnectivity = false
        return URLSession(configuration: configuration)
    }()

    /// `jsonSchema` is a plain JSON dictionary, which Swift cannot prove
    /// `Sendable`. It is built once per request and never mutated after,
    /// so crossing a task boundary with it is safe.
    public struct Request: @unchecked Sendable {
        public var model: ClaudeModel
        public var system: String
        public var userMessage: String
        /// When set, the reply is constrained to this JSON Schema.
        public var jsonSchema: [String: Any]?
        public var enableWebSearch: Bool
        public var maxWebSearches: Int
        public var maxTokens: Int
        /// One of `low`, `medium`, `high`, `xhigh`, `max`. Ignored for models
        /// that do not support effort.
        public var effort: String?

        public init(
            model: ClaudeModel,
            system: String,
            userMessage: String,
            jsonSchema: [String: Any]? = nil,
            enableWebSearch: Bool = true,
            maxWebSearches: Int = 6,
            maxTokens: Int = 16000,
            effort: String? = "high"
        ) {
            self.model = model
            self.system = system
            self.userMessage = userMessage
            self.jsonSchema = jsonSchema
            self.enableWebSearch = enableWebSearch
            self.maxWebSearches = maxWebSearches
            self.maxTokens = maxTokens
            self.effort = effort
        }
    }

    public struct Usage: Sendable, Equatable {
        public let inputTokens: Int
        public let outputTokens: Int

        public init(inputTokens: Int, outputTokens: Int) {
            self.inputTokens = inputTokens
            self.outputTokens = outputTokens
        }
    }

    public struct Response: Sendable {
        /// Every `text` block in the reply, concatenated.
        public let text: String
        public let usage: Usage
        /// How many web searches the model actually ran, across all turns.
        public let webSearchCount: Int
        /// URLs the model saw in its search results, in the order returned.
        public let sourceURLs: [String]

        public init(text: String, usage: Usage, webSearchCount: Int, sourceURLs: [String]) {
            self.text = text
            self.usage = usage
            self.webSearchCount = webSearchCount
            self.sourceURLs = sourceURLs
        }
    }

    public enum ClientError: LocalizedError, Sendable {
        case missingAPIKey
        case invalidAPIKey
        case rateLimited(retryAfter: TimeInterval?)
        case overloaded
        case refused(String)
        case requestFailed(status: Int, message: String)
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "AI tag verification needs an Anthropic API key. Add one in Settings → API Keys, or set EZLIBRARY_ANTHROPIC_KEY."
            case .invalidAPIKey:
                return "Anthropic rejected the API key. Check the key in Settings → API Keys."
            case let .rateLimited(retryAfter):
                if let retryAfter {
                    return "Anthropic is rate limiting this key. Wait about \(Int(retryAfter.rounded())) seconds and run it again, or verify fewer tracks at a time."
                }
                return "Anthropic is rate limiting this key. Wait a minute and run it again, or verify fewer tracks at a time."
            case .overloaded:
                return "Anthropic's API is overloaded right now. Try again in a few minutes."
            case let .refused(detail):
                return "Claude declined to answer for this track\(detail.isEmpty ? "." : ": \(detail)")"
            case let .requestFailed(status, message):
                return "Claude request failed (HTTP \(status)): \(message)"
            case let .invalidResponse(detail):
                return "Claude returned an unexpected response: \(detail)"
            }
        }

        /// True when waiting and retrying is the right move.
        public var isRetryable: Bool {
            switch self {
            case .rateLimited, .overloaded:
                return true
            case .missingAPIKey, .invalidAPIKey, .refused, .requestFailed, .invalidResponse:
                return false
            }
        }
    }

    // MARK: - Credentials

    public static func apiKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> String? {
        if let value = userDefaults.string(forKey: apiKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        if let value = environment[apiKeyEnvironmentKey]?
            .trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty {
            return value
        }
        return nil
    }

    public static func hasAPIKey(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Bool {
        apiKey(environment: environment, userDefaults: userDefaults) != nil
    }

    /// The model chosen in Settings, defaulting to Opus 5.
    public static func selectedModel(userDefaults: UserDefaults = .standard) -> ClaudeModel {
        guard let raw = userDefaults.string(forKey: modelDefaultsKey),
              let model = ClaudeModel(rawValue: raw) else {
            return .opus5
        }
        return model
    }

    /// Cheapest possible round trip that still proves the key works.
    public static func validateAPIKey(
        _ key: String,
        session: URLSession = defaultSession
    ) async throws -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ClientError.missingAPIKey }

        let body: [String: Any] = [
            "model": ClaudeModel.haiku45.rawValue,
            "max_tokens": 1,
            "messages": [["role": "user", "content": "ping"]]
        ]
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "content-type")
        request.setValue(trimmed, forHTTPHeaderField: "x-api-key")
        request.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw ClientError.invalidResponse("no HTTP response")
        }
        switch http.statusCode {
        case 200...299:
            return true
        case 401, 403:
            throw ClientError.invalidAPIKey
        default:
            throw ClientError.requestFailed(status: http.statusCode, message: errorMessage(from: data))
        }
    }

    // MARK: - Sending

    /// Sends one request and returns the model's final reply.
    ///
    /// Handles the two continuation rules the Messages API imposes on
    /// server-tool turns: a `pause_turn` stop reason means the server-side
    /// search loop hit its iteration cap and the same conversation must be
    /// re-sent to resume it, and throttled or overloaded responses are retried
    /// with backoff rather than surfaced as a failed lookup.
    public static func send(
        _ request: Request,
        apiKey key: String? = nil,
        session: URLSession = defaultSession,
        maxContinuations: Int = 4,
        maxAttempts: Int = 3
    ) async throws -> Response {
        guard let resolvedKey = key ?? apiKey() else {
            throw ClientError.missingAPIKey
        }

        var messages: [[String: Any]] = [
            ["role": "user", "content": request.userMessage]
        ]
        var accumulatedText = ""
        var inputTokens = 0
        var outputTokens = 0
        var webSearchCount = 0
        var sourceURLs: [String] = []
        // Cleared if the API turns out to reject a schema-constrained reply
        // alongside web search; see `shouldRetryWithoutSchema`.
        var schema = request.jsonSchema

        for _ in 0...maxContinuations {
            let body = requestBody(for: request, messages: messages, schema: schema)
            let payload: [String: Any]
            do {
                payload = try await perform(
                    body: body,
                    model: request.model,
                    apiKey: resolvedKey,
                    session: session,
                    maxAttempts: maxAttempts
                )
            } catch let error as ClientError {
                // A schema the API won't accept in combination with web search
                // is worth one retry without it: the prompt asks for the same
                // JSON either way, so the reply is still parseable.
                if schema != nil, shouldRetryWithoutSchema(error) {
                    schema = nil
                    continue
                }
                throw error
            }

            if let usage = payload["usage"] as? [String: Any] {
                inputTokens += (usage["input_tokens"] as? Int) ?? 0
                outputTokens += (usage["output_tokens"] as? Int) ?? 0
            }

            let content = (payload["content"] as? [[String: Any]]) ?? []
            accumulatedText += textFrom(content: content)
            webSearchCount += webSearchUses(in: content)
            sourceURLs.append(contentsOf: searchResultURLs(in: content))

            let stopReason = payload["stop_reason"] as? String
            if stopReason == "refusal" {
                let detail = (payload["stop_details"] as? [String: Any])?["explanation"] as? String
                throw ClientError.refused(detail ?? "")
            }

            guard stopReason == "pause_turn" else {
                let text = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !text.isEmpty else {
                    throw ClientError.invalidResponse("the reply contained no text (stop reason: \(stopReason ?? "unknown"))")
                }
                return Response(
                    text: text,
                    usage: Usage(inputTokens: inputTokens, outputTokens: outputTokens),
                    webSearchCount: webSearchCount,
                    sourceURLs: sourceURLs
                )
            }

            // Resume: echo the paused assistant turn back verbatim. The API
            // detects the trailing server-tool block and picks up where it
            // stopped — adding a "continue" message of our own would derail it.
            messages.append(["role": "assistant", "content": content])
        }

        throw ClientError.invalidResponse("the model kept searching past \(maxContinuations) continuations without answering")
    }

    /// Builds the wire body. Split out so tests can assert on which
    /// per-model parameters are included without making a network call.
    static func requestBody(
        for request: Request,
        messages: [[String: Any]],
        schema: [String: Any]?
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": request.model.rawValue,
            "max_tokens": request.maxTokens,
            "system": request.system,
            "messages": messages
        ]

        if request.enableWebSearch {
            body["tools"] = [
                [
                    "type": request.model.webSearchToolType,
                    "name": "web_search",
                    "max_uses": request.maxWebSearches
                ]
            ]
        }

        var outputConfig: [String: Any] = [:]
        if let schema {
            outputConfig["format"] = ["type": "json_schema", "schema": schema]
        }
        if request.model.supportsEffort, let effort = request.effort {
            outputConfig["effort"] = effort
        }
        if !outputConfig.isEmpty {
            body["output_config"] = outputConfig
        }

        if request.model.supportsAdaptiveThinking {
            body["thinking"] = ["type": "adaptive"]
        }

        if request.model.supportsServerSideFallback {
            // If a safety classifier declines the request, the API re-runs it
            // on a fallback model in the same call instead of returning
            // nothing. Music metadata rarely trips one, but a refusal that
            // silently produced no verdict would look like a bug.
            body["fallbacks"] = "default"
        }

        return body
    }

    private static func perform(
        body: [String: Any],
        model: ClaudeModel,
        apiKey key: String,
        session: URLSession,
        maxAttempts: Int
    ) async throws -> [String: Any] {
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "content-type")
        urlRequest.setValue(key, forHTTPHeaderField: "x-api-key")
        urlRequest.setValue(apiVersion, forHTTPHeaderField: "anthropic-version")
        if model.supportsServerSideFallback {
            urlRequest.setValue(serverSideFallbackBeta, forHTTPHeaderField: "anthropic-beta")
        }
        urlRequest.httpBody = try JSONSerialization.data(withJSONObject: body)

        var lastError: ClientError?
        for attempt in 1...maxAttempts {
            let (data, response) = try await session.data(for: urlRequest)
            guard let http = response as? HTTPURLResponse else {
                throw ClientError.invalidResponse("no HTTP response")
            }

            switch http.statusCode {
            case 200...299:
                guard let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                    throw ClientError.invalidResponse("body was not a JSON object")
                }
                return payload
            case 401, 403:
                throw ClientError.invalidAPIKey
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
                let throttled = ClientError.rateLimited(retryAfter: retryAfter)
                lastError = throttled
                if attempt == maxAttempts { throw throttled }
                try await sleep(seconds: retryAfter ?? backoffSeconds(for: attempt))
            case 529:
                lastError = .overloaded
                if attempt == maxAttempts { throw ClientError.overloaded }
                try await sleep(seconds: backoffSeconds(for: attempt))
            case 500...599:
                let failure = ClientError.requestFailed(status: http.statusCode, message: errorMessage(from: data))
                lastError = failure
                if attempt == maxAttempts { throw failure }
                try await sleep(seconds: backoffSeconds(for: attempt))
            default:
                throw ClientError.requestFailed(status: http.statusCode, message: errorMessage(from: data))
            }
        }

        throw lastError ?? ClientError.invalidResponse("request failed with no response")
    }

    /// Scales every retry wait. Tests set it to 0 so backoff logic runs without
    /// actually sleeping.
    nonisolated(unsafe) static var retryDelayScale: Double = 1.0

    private static func backoffSeconds(for attempt: Int) -> TimeInterval {
        min(16, pow(2, Double(attempt)))
    }

    private static func sleep(seconds: TimeInterval) async throws {
        let scaled = seconds * retryDelayScale
        guard scaled > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(scaled * 1_000_000_000))
    }

    /// True for the narrow case of the API rejecting the JSON-schema reply
    /// format itself, as opposed to anything wrong with the request's content.
    static func shouldRetryWithoutSchema(_ error: ClientError) -> Bool {
        guard case let .requestFailed(status, message) = error, status == 400 else { return false }
        let lowered = message.lowercased()
        return lowered.contains("output_config")
            || lowered.contains("json_schema")
            || lowered.contains("citation")
    }

    // MARK: - Response parsing

    static func textFrom(content: [[String: Any]]) -> String {
        content
            .filter { ($0["type"] as? String) == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
    }

    static func webSearchUses(in content: [[String: Any]]) -> Int {
        content.filter {
            ($0["type"] as? String) == "server_tool_use" && ($0["name"] as? String) == "web_search"
        }.count
    }

    /// Pulls the result URLs out of `web_search_tool_result` blocks so the
    /// review UI can show what the verdict was actually based on.
    ///
    /// A successful block's `content` is a *list* of results; an errored one is
    /// a single object (`{"error_code": ...}`), which is why this checks the
    /// shape instead of indexing straight into it.
    static func searchResultURLs(in content: [[String: Any]]) -> [String] {
        var urls: [String] = []
        for block in content where (block["type"] as? String) == "web_search_tool_result" {
            guard let results = block["content"] as? [[String: Any]] else { continue }
            for result in results {
                if let url = result["url"] as? String, !urls.contains(url) {
                    urls.append(url)
                }
            }
        }
        return urls
    }

    private static func errorMessage(from data: Data) -> String {
        guard let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let error = payload["error"] as? [String: Any],
              let message = error["message"] as? String else {
            let raw = String(data: data, encoding: .utf8) ?? ""
            return raw.isEmpty ? "no error detail" : String(raw.prefix(300))
        }
        return message
    }
}
