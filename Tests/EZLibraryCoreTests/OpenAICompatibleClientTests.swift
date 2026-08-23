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

private func makeDefaults() -> (UserDefaults, String) {
    let suite = "OpenAICompatTests-\(UUID().uuidString)"
    return (UserDefaults(suiteName: suite)!, suite)
}

@Test func baseURLsAreNormalisedIntoACompletionsEndpoint() throws {
    #expect(try OpenAICompatibleClient.completionsURL(from: "https://api.openai.com/v1").absoluteString
            == "https://api.openai.com/v1/chat/completions")
    // A pasted URL very often carries a trailing slash.
    #expect(try OpenAICompatibleClient.completionsURL(from: "https://api.openai.com/v1/").absoluteString
            == "https://api.openai.com/v1/chat/completions")
    // Or the user pasted the full endpoint already.
    #expect(try OpenAICompatibleClient.completionsURL(from: "https://x.dev/v1/chat/completions").absoluteString
            == "https://x.dev/v1/chat/completions")
}

@Test func anUnusableBaseURLIsRejectedWithAReadableError() {
    #expect(throws: OpenAICompatibleClient.ClientError.self) {
        try OpenAICompatibleClient.completionsURL(from: "not a url")
    }
    #expect(throws: OpenAICompatibleClient.ClientError.self) {
        try OpenAICompatibleClient.completionsURL(from: "   ")
    }
}

@Test func localEndpointsAreRecognised() {
    #expect(OpenAICompatibleClient.isLocalEndpoint("http://localhost:11434/v1"))
    #expect(OpenAICompatibleClient.isLocalEndpoint("http://127.0.0.1:1234/v1"))
    #expect(!OpenAICompatibleClient.isLocalEndpoint("https://api.openai.com/v1"))
}

@Test func aLocalEndpointNeedsNoAPIKey() {
    // Ollama and LM Studio take no credential; demanding one would make the
    // free local path impossible to configure.
    let (defaults, suite) = makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    defaults.set("http://localhost:11434/v1", forKey: OpenAICompatibleClient.baseURLDefaultsKey)
    defaults.set("llama3.1", forKey: OpenAICompatibleClient.modelDefaultsKey)

    let configuration = OpenAICompatibleClient.configuration(environment: [:], userDefaults: defaults)
    #expect(configuration?.model == "llama3.1")
    #expect(configuration?.apiKey.isEmpty == true)
}

@Test func aRemoteEndpointWithoutAKeyIsNotConfigured() {
    let (defaults, suite) = makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    defaults.set("https://api.openai.com/v1", forKey: OpenAICompatibleClient.baseURLDefaultsKey)
    defaults.set("gpt-5", forKey: OpenAICompatibleClient.modelDefaultsKey)

    #expect(OpenAICompatibleClient.configuration(environment: [:], userDefaults: defaults) == nil)
}

@Test func aMissingModelNameMeansNotConfigured() {
    let (defaults, suite) = makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    defaults.set("https://api.openai.com/v1", forKey: OpenAICompatibleClient.baseURLDefaultsKey)
    defaults.set("sk-test", forKey: OpenAICompatibleClient.apiKeyDefaultsKey)

    #expect(OpenAICompatibleClient.configuration(environment: [:], userDefaults: defaults) == nil)
}

@Test func theEnvironmentSuppliesTheKeyWhenNoneIsSaved() {
    let (defaults, suite) = makeDefaults()
    defer { UserDefaults.standard.removePersistentDomain(forName: suite) }

    defaults.set("https://api.openai.com/v1", forKey: OpenAICompatibleClient.baseURLDefaultsKey)
    defaults.set("gpt-5", forKey: OpenAICompatibleClient.modelDefaultsKey)

    let configuration = OpenAICompatibleClient.configuration(
        environment: [OpenAICompatibleClient.apiKeyEnvironmentKey: "sk-env"],
        userDefaults: defaults
    )
    #expect(configuration?.apiKey == "sk-env")
}

@Test func theRequestBodyCarriesTheModelAndBothMessages() throws {
    let body = OpenAICompatibleClient.requestBody(
        model: "gpt-5",
        system: "sys",
        user: "usr",
        requestJSONObject: true
    )

    #expect(body["model"] as? String == "gpt-5")
    let messages = try #require(body["messages"] as? [[String: Any]])
    #expect(messages.count == 2)
    #expect(messages[0]["role"] as? String == "system")
    #expect(messages[1]["content"] as? String == "usr")
    #expect((body["response_format"] as? [String: Any])?["type"] as? String == "json_object")
}

@Test func theRetryBodyDropsTheResponseFormat() {
    // Some OpenAI-compatible servers reject `response_format` outright; the
    // retry has to be a plain request or "any provider" is not true.
    let body = OpenAICompatibleClient.requestBody(
        model: "local-model",
        system: "sys",
        user: "usr",
        requestJSONObject: false
    )
    #expect(body["response_format"] == nil)
}

@Test func aChatCompletionReplyIsParsedWithItsTokenUsage() throws {
    let json = """
    {"choices": [{"message": {"role": "assistant", "content": "{\\"ok\\": true}"}}],
     "usage": {"prompt_tokens": 120, "completion_tokens": 34}}
    """
    let response = try OpenAICompatibleClient.parse(Data(json.utf8))
    #expect(response.text == "{\"ok\": true}")
    #expect(response.usage.inputTokens == 120)
    #expect(response.usage.outputTokens == 34)
}

@Test func aReplyWithNoContentIsReportedRatherThanReturnedEmpty() {
    #expect(throws: OpenAICompatibleClient.ClientError.self) {
        try OpenAICompatibleClient.parse(Data("{\"choices\": []}".utf8))
    }
    #expect(throws: OpenAICompatibleClient.ClientError.self) {
        try OpenAICompatibleClient.parse(Data("not json".utf8))
    }
}

@Test func replyParsingToleratesMissingUsage() throws {
    let json = "{\"choices\": [{\"message\": {\"content\": \"hi\"}}]}"
    let response = try OpenAICompatibleClient.parse(Data(json.utf8))
    #expect(response.usage.inputTokens == 0)
}

@Test func everyPresetHasAUsableBaseURL() throws {
    for preset in OpenAICompatibleClient.presets {
        #expect(throws: Never.self) {
            try OpenAICompatibleClient.completionsURL(from: preset.baseURL)
        }
        #expect(!preset.exampleModel.isEmpty)
    }
    #expect(OpenAICompatibleClient.presets.contains { $0.isLocal })
}
