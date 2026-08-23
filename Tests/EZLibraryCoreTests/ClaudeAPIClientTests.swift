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
import Testing
@testable import EZLibraryCore

private func body(
    for model: ClaudeModel,
    webSearch: Bool = true,
    schema: [String: Any]? = ["type": "object"]
) -> [String: Any] {
    let request = ClaudeAPIClient.Request(
        model: model,
        system: "system",
        userMessage: "user",
        jsonSchema: schema,
        enableWebSearch: webSearch
    )
    return ClaudeAPIClient.requestBody(
        for: request,
        messages: [["role": "user", "content": "user"]],
        schema: schema
    )
}

@Test func opus5RequestCarriesTheModernParameters() {
    let payload = body(for: .opus5)

    #expect(payload["model"] as? String == "claude-opus-5")
    // Adaptive thinking replaced the removed `budget_tokens` form; sending the
    // old shape to this model is a 400.
    #expect((payload["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
    #expect(payload["fallbacks"] as? String == "default")

    let outputConfig = payload["output_config"] as? [String: Any]
    #expect(outputConfig?["effort"] as? String == "high")
    #expect((outputConfig?["format"] as? [String: Any])?["type"] as? String == "json_schema")

    let tools = payload["tools"] as? [[String: Any]]
    #expect(tools?.first?["type"] as? String == "web_search_20260209")
    #expect(tools?.first?["name"] as? String == "web_search")
}

@Test func haikuRequestOmitsParametersThatModelRejects() {
    let payload = body(for: .haiku45)

    // Haiku 4.5 predates adaptive thinking, effort, and server-side fallbacks;
    // including any of them fails the request outright.
    #expect(payload["thinking"] == nil)
    #expect(payload["fallbacks"] == nil)
    #expect((payload["output_config"] as? [String: Any])?["effort"] == nil)
    // It also only accepts the original web search tool.
    #expect((payload["tools"] as? [[String: Any]])?.first?["type"] as? String == "web_search_20250305")
}

@Test func sonnetRequestKeepsEffortButNotFallbacks() {
    let payload = body(for: .sonnet5)

    #expect((payload["thinking"] as? [String: Any])?["type"] as? String == "adaptive")
    #expect((payload["output_config"] as? [String: Any])?["effort"] as? String == "high")
    #expect(payload["fallbacks"] == nil)
}

@Test func disablingWebSearchRemovesTheToolBlock() {
    #expect(body(for: .opus5, webSearch: false)["tools"] == nil)
}

@Test func omittingTheSchemaLeavesOnlyEffortInOutputConfig() {
    let payload = body(for: .opus5, schema: nil)
    let outputConfig = payload["output_config"] as? [String: Any]
    #expect(outputConfig?["format"] == nil)
    #expect(outputConfig?["effort"] as? String == "high")
}

@Test func textBlocksAreConcatenatedAndOtherBlocksIgnored() {
    let content: [[String: Any]] = [
        ["type": "thinking", "thinking": ""],
        ["type": "text", "text": "{\"a\":"],
        ["type": "server_tool_use", "name": "web_search"],
        ["type": "text", "text": "1}"]
    ]
    #expect(ClaudeAPIClient.textFrom(content: content) == "{\"a\":1}")
    #expect(ClaudeAPIClient.webSearchUses(in: content) == 1)
}

@Test func searchResultURLsAreCollectedWithoutDuplicates() {
    let content: [[String: Any]] = [
        ["type": "web_search_tool_result", "content": [
            ["url": "https://example.com/a"],
            ["url": "https://example.com/b"],
            ["url": "https://example.com/a"]
        ]]
    ]
    #expect(ClaudeAPIClient.searchResultURLs(in: content) == [
        "https://example.com/a",
        "https://example.com/b"
    ])
}

@Test func erroredSearchResultBlocksDoNotCrashURLCollection() {
    // A throttled or failed search returns an object here, not a list. Indexing
    // straight into it would trap.
    let content: [[String: Any]] = [
        ["type": "web_search_tool_result", "content": ["error_code": "max_uses_exceeded"]]
    ]
    #expect(ClaudeAPIClient.searchResultURLs(in: content).isEmpty)
}

@Test func onlySchemaRejectionsTriggerTheSchemaFreeRetry() {
    #expect(ClaudeAPIClient.shouldRetryWithoutSchema(
        .requestFailed(status: 400, message: "output_config.format is not supported here")
    ))
    #expect(ClaudeAPIClient.shouldRetryWithoutSchema(
        .requestFailed(status: 400, message: "citations cannot be combined with this")
    ))
    // A different 400 is a real problem and must surface, not be retried away.
    #expect(!ClaudeAPIClient.shouldRetryWithoutSchema(
        .requestFailed(status: 400, message: "max_tokens must be positive")
    ))
    #expect(!ClaudeAPIClient.shouldRetryWithoutSchema(.invalidAPIKey))
}

@Test func retryableErrorsAreClassifiedForTheCaller() {
    #expect(ClaudeAPIClient.ClientError.rateLimited(retryAfter: 30).isRetryable)
    #expect(ClaudeAPIClient.ClientError.overloaded.isRetryable)
    #expect(!ClaudeAPIClient.ClientError.invalidAPIKey.isRetryable)
    #expect(!ClaudeAPIClient.ClientError.missingAPIKey.isRetryable)
}

@Test func apiKeyPrefersSavedValueThenEnvironment() {
    let defaults = TestDefaults.inMemory()

    #expect(ClaudeAPIClient.apiKey(environment: [:], userDefaults: defaults) == nil)

    let environment = [ClaudeAPIClient.apiKeyEnvironmentKey: "sk-env"]
    #expect(ClaudeAPIClient.apiKey(environment: environment, userDefaults: defaults) == "sk-env")

    defaults.set("  sk-saved  ", forKey: ClaudeAPIClient.apiKeyDefaultsKey)
    #expect(ClaudeAPIClient.apiKey(environment: environment, userDefaults: defaults) == "sk-saved")
}

@Test func selectedModelFallsBackToOpusForUnknownValues() {
    let defaults = TestDefaults.inMemory()

    #expect(ClaudeAPIClient.selectedModel(userDefaults: defaults) == .opus5)
    defaults.set("claude-haiku-4-5", forKey: ClaudeAPIClient.modelDefaultsKey)
    #expect(ClaudeAPIClient.selectedModel(userDefaults: defaults) == .haiku45)
    defaults.set("gpt-nonsense", forKey: ClaudeAPIClient.modelDefaultsKey)
    #expect(ClaudeAPIClient.selectedModel(userDefaults: defaults) == .opus5)
}
