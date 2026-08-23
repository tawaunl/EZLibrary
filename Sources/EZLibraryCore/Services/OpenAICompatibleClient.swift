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

/// Talks to any service that speaks OpenAI's `/chat/completions` shape.
///
/// That one wire format is what makes "bring a key from whichever model you
/// like" tractable: OpenAI, Groq, OpenRouter, Together, Mistral, DeepSeek,
/// LM Studio, and Ollama all accept it, so a base URL and a model name cover
/// nearly every provider a user might already be paying for — including local
/// ones, where the key is irrelevant and the cost is zero.
///
/// What none of them share is a *server-side web search*. Only the native
/// Anthropic path has that. A model reached through here still gets the full
/// evidence bundle — fingerprint match, database candidates, filename, current
/// tags — so it has real material to judge; it simply cannot go and look
/// anything else up.
public enum OpenAICompatibleClient {
    public static let apiKeyDefaultsKey = "SeratoToolsOpenAICompatibleKey"
    public static let baseURLDefaultsKey = "SeratoToolsOpenAICompatibleBaseURL"
    public static let modelDefaultsKey = "SeratoToolsOpenAICompatibleModel"
    public static let apiKeyEnvironmentKey = "EZLIBRARY_OPENAI_COMPATIBLE_KEY"

    public static let defaultBaseURL = "https://api.openai.com/v1"

    /// Presets for the endpoints people most often already have a key for.
    /// The list is a convenience, not a limit — any OpenAI-compatible base URL
    /// works.
    public struct Preset: Sendable, Hashable, Identifiable {
        public let name: String
        public let baseURL: String
        public let exampleModel: String
        /// True when the endpoint runs on the user's own machine, so there is
        /// no key and no bill.
        public let isLocal: Bool

        public var id: String { baseURL }

        public init(name: String, baseURL: String, exampleModel: String, isLocal: Bool = false) {
            self.name = name
            self.baseURL = baseURL
            self.exampleModel = exampleModel
            self.isLocal = isLocal
        }
    }

    public static let presets: [Preset] = [
        Preset(name: "OpenAI", baseURL: "https://api.openai.com/v1", exampleModel: "gpt-5"),
        Preset(name: "OpenRouter", baseURL: "https://openrouter.ai/api/v1", exampleModel: "openai/gpt-5"),
        Preset(name: "Groq", baseURL: "https://api.groq.com/openai/v1", exampleModel: "llama-3.3-70b-versatile"),
        Preset(name: "Mistral", baseURL: "https://api.mistral.ai/v1", exampleModel: "mistral-large-latest"),
        Preset(name: "DeepSeek", baseURL: "https://api.deepseek.com/v1", exampleModel: "deepseek-chat"),
        Preset(name: "Ollama (this Mac)", baseURL: "http://localhost:11434/v1", exampleModel: "llama3.1", isLocal: true),
        Preset(name: "LM Studio (this Mac)", baseURL: "http://localhost:1234/v1", exampleModel: "local-model", isLocal: true)
    ]

    public enum ClientError: LocalizedError {
        case missingConfiguration(String)
        case invalidBaseURL(String)
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case requestFailed(status: Int, message: String)
        case invalidResponse(String)

        public var errorDescription: String? {
            switch self {
            case let .missingConfiguration(what):
                return "\(what) is not set. Fill it in under Settings → API Keys."
            case let .invalidBaseURL(value):
                return "\"\(value)\" is not a usable API base URL. It should look like https://api.openai.com/v1."
            case .unauthorized:
                return "The provider rejected the API key. Check the key and the base URL in Settings → API Keys."
            case let .rateLimited(retryAfter):
                if let retryAfter {
                    return "The provider is rate limiting this key. Wait about \(Int(retryAfter.rounded())) seconds and try again."
                }
                return "The provider is rate limiting this key. Wait a minute and try again, or verify fewer tracks at a time."
            case let .requestFailed(status, message):
                return "The provider returned HTTP \(status): \(message)"
            case let .invalidResponse(detail):
                return "The provider returned an unexpected response: \(detail)"
            }
        }
    }

    public struct Configuration: Sendable {
        public let baseURL: String
        public let model: String
        public let apiKey: String

        public init(baseURL: String, model: String, apiKey: String) {
            self.baseURL = baseURL
            self.model = model
            self.apiKey = apiKey
        }
    }

    public static func configuration(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        userDefaults: UserDefaults = .standard
    ) -> Configuration? {
        let baseURL = (userDefaults.string(forKey: baseURLDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)).flatMap { $0.isEmpty ? nil : $0 }
            ?? defaultBaseURL
        guard let model = userDefaults.string(forKey: modelDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines), !model.isEmpty else {
            return nil
        }

        let key = (userDefaults.string(forKey: apiKeyDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines))
            ?? environment[apiKeyEnvironmentKey]?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? ""

        // A local endpoint needs no key, so a blank one is only a problem when
        // the request is going somewhere off this machine.
        if key.isEmpty, !isLocalEndpoint(baseURL) {
            return nil
        }

        return Configuration(baseURL: baseURL, model: model, apiKey: key)
    }

    static func isLocalEndpoint(_ baseURL: String) -> Bool {
        guard let host = URL(string: baseURL)?.host?.lowercased() else { return false }
        return host == "localhost" || host == "127.0.0.1" || host == "::1" || host.hasSuffix(".local")
    }

    /// Builds the `/chat/completions` URL from a base that may or may not carry
    /// a trailing slash or already end in the path.
    static func completionsURL(from baseURL: String) throws -> URL {
        var trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") {
            trimmed.removeLast()
        }
        guard !trimmed.isEmpty, let base = URL(string: trimmed), base.scheme != nil else {
            throw ClientError.invalidBaseURL(baseURL)
        }
        if trimmed.hasSuffix("/chat/completions") {
            return base
        }
        return base.appendingPathComponent("chat/completions")
    }

    public struct Response: Sendable {
        public let text: String
        public let usage: TagVerificationUsage

        public init(text: String, usage: TagVerificationUsage) {
            self.text = text
            self.usage = usage
        }
    }

    static func requestBody(
        model: String,
        system: String,
        user: String,
        requestJSONObject: Bool
    ) -> [String: Any] {
        var body: [String: Any] = [
            "model": model,
            "messages": [
                ["role": "system", "content": system],
                ["role": "user", "content": user]
            ]
        ]
        if requestJSONObject {
            // The widely-supported form. `json_schema` is newer and many
            // OpenAI-compatible servers reject it outright, which would make
            // "any provider" false in practice.
            body["response_format"] = ["type": "json_object"]
        }
        return body
    }

    public static func send(
        system: String,
        user: String,
        configuration: Configuration,
        session: URLSession = ClaudeAPIClient.defaultSession
    ) async throws -> Response {
        let url = try completionsURL(from: configuration.baseURL)

        // Try with a JSON-object response format, and once without: some
        // servers 400 on `response_format` entirely, and the prompt already
        // asks for JSON, so the retry still parses.
        var lastError: Error?
        for requestJSONObject in [true, false] {
            var request = URLRequest(url: url)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "content-type")
            if !configuration.apiKey.isEmpty {
                request.setValue("Bearer \(configuration.apiKey)", forHTTPHeaderField: "authorization")
            }
            request.httpBody = try JSONSerialization.data(
                withJSONObject: requestBody(
                    model: configuration.model,
                    system: system,
                    user: user,
                    requestJSONObject: requestJSONObject
                )
            )

            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw ClientError.invalidResponse("no HTTP response")
            }

            switch http.statusCode {
            case 200...299:
                return try parse(data)
            case 401, 403:
                throw ClientError.unauthorized
            case 429:
                let retryAfter = http.value(forHTTPHeaderField: "retry-after").flatMap(TimeInterval.init)
                throw ClientError.rateLimited(retryAfter: retryAfter)
            case 400 where requestJSONObject:
                // Most likely the unsupported response_format; fall through to
                // the plain retry rather than reporting a dead end.
                lastError = ClientError.requestFailed(status: 400, message: errorMessage(from: data))
                continue
            default:
                throw ClientError.requestFailed(status: http.statusCode, message: errorMessage(from: data))
            }
        }

        throw lastError ?? ClientError.invalidResponse("the request could not be completed")
    }

    static func parse(_ data: Data) throws -> Response {
        // JSONSerialization throws NSCocoaErrorDomain 3840 on non-JSON, whose
        // message ("JSON text did not start with array or object…") is not
        // something to show a DJ. A misconfigured base URL returning an HTML
        // error page lands here routinely.
        guard let decoded = try? JSONSerialization.jsonObject(with: data),
              let payload = decoded as? [String: Any] else {
            throw ClientError.invalidResponse(
                "the reply was not JSON — check that the base URL points at an OpenAI-compatible API"
            )
        }
        guard let choices = payload["choices"] as? [[String: Any]],
              let message = choices.first?["message"] as? [String: Any],
              let content = message["content"] as? String else {
            throw ClientError.invalidResponse("no message content in the reply")
        }

        let usage = payload["usage"] as? [String: Any]
        return Response(
            text: content,
            usage: TagVerificationUsage(
                inputTokens: (usage?["prompt_tokens"] as? Int) ?? 0,
                outputTokens: (usage?["completion_tokens"] as? Int) ?? 0
            )
        )
    }

    /// Cheapest round trip that proves the endpoint, key, and model all work
    /// together — the three things that are wrong when this is misconfigured.
    public static func validate(
        configuration: Configuration,
        session: URLSession = ClaudeAPIClient.defaultSession
    ) async throws -> Bool {
        _ = try await send(
            system: "Reply with the single word ok.",
            user: "ping",
            configuration: configuration,
            session: session
        )
        return true
    }

    private static func errorMessage(from data: Data) -> String {
        if let payload = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if let error = payload["error"] as? [String: Any],
               let message = error["message"] as? String {
                return message
            }
            if let message = payload["error"] as? String {
                return message
            }
        }
        let raw = String(data: data, encoding: .utf8) ?? ""
        return raw.isEmpty ? "no error detail" : String(raw.prefix(300))
    }
}
