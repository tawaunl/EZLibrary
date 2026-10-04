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

// MARK: - The three models

@Test func threeOpenAIModelsMirrorTheThreeClaudeTiers() {
    #expect(OpenAIModel.allCases.map(\.rawValue) == ["gpt-6-astra", "gpt-6.1-sol", "gpt-6-luna"])
    #expect(OpenAIModel.allCases.count == ClaudeModel.allCases.count)
    #expect(OpenAIModel.default == .sol)
    #expect(OpenAIModel.astra.displayName.contains("most accurate"))
    #expect(OpenAIModel.sol.displayName.contains("balanced"))
    #expect(OpenAIModel.luna.displayName.contains("cheapest"))
}

@Test func openAIPricesMatchThePublishedStandardShortContextRates() {
    #expect(OpenAIModel.astra.pricing == ModelPricing(input: 10, output: 50, cacheRead: 1, cacheWrite: 12.5))
    #expect(OpenAIModel.sol.pricing == ModelPricing(input: 2, output: 10, cacheRead: 0.10, cacheWrite: 2.5))
    #expect(OpenAIModel.luna.pricing == ModelPricing(input: 0.10, output: 0.50, cacheRead: 0.01, cacheWrite: 0.125))
}

@Test func claudePricingBundlesTheSameRatesTheModelReports() {
    let pricing = ClaudeModel.opus55.pricing
    #expect(pricing == ModelPricing(input: 4, output: 20, cacheRead: 0.20, cacheWrite: 5))
    let usage = TagVerificationUsage(inputTokens: 1_000, outputTokens: 1_000, cacheWriteTokens: 1_000, cacheReadTokens: 1_000)
    #expect(usage.tokenCost(on: .opus55) == usage.tokenCost(at: pricing))
}

// MARK: - Knowing the price

@Test func aPriceIsKnownOnlyForTheBuiltInModelsOnOpenAIOrAModelOnThisMac() {
    let openAI = "https://api.openai.com/v1"
    #expect(OpenAICompatibleClient.pricing(baseURL: openAI, model: "gpt-6.1-sol") == OpenAIModel.sol.pricing)
    // An OpenAI model we have no price for.
    #expect(OpenAICompatibleClient.pricing(baseURL: openAI, model: "gpt-4o") == nil)
    // The same name through another provider is billed at that provider's rates.
    #expect(OpenAICompatibleClient.pricing(baseURL: "https://openrouter.ai/api/v1", model: "gpt-6.1-sol") == nil)
    #expect(OpenAICompatibleClient.pricing(baseURL: "http://localhost:11434/v1", model: "llama3.1") == .free)
}

@Test func theSelectedEndpointFallsBackToTheDefaultModelOnlyOnOpenAI() {
    let defaults = TestDefaults.inMemory()
    #expect(OpenAICompatibleClient.selectedEndpoint(userDefaults: defaults)?.model == "gpt-6.1-sol")

    defaults.set("gpt-6-luna", forKey: OpenAICompatibleClient.modelDefaultsKey)
    #expect(OpenAICompatibleClient.selectedEndpoint(userDefaults: defaults)?.model == "gpt-6-luna")

    defaults.set("https://api.groq.com/openai/v1", forKey: OpenAICompatibleClient.baseURLDefaultsKey)
    defaults.set("", forKey: OpenAICompatibleClient.modelDefaultsKey)
    #expect(OpenAICompatibleClient.selectedEndpoint(userDefaults: defaults) == nil)
}

// MARK: - Usage

@Test func cachedTokensAreSplitOutOfOpenAIsPromptCount() throws {
    let reply = Data("""
    {"choices":[{"message":{"content":"{}"}}],
     "usage":{"prompt_tokens":2600,"completion_tokens":900,"prompt_tokens_details":{"cached_tokens":1100}}}
    """.utf8)
    let response = try OpenAICompatibleClient.parse(reply)
    // Counted inside prompt_tokens by OpenAI; billed once here, as a read.
    #expect(response.usage == TagVerificationUsage(inputTokens: 1500, outputTokens: 900, cacheReadTokens: 1100))
}

@Test func aReplyWithoutCacheDetailsCountsEveryPromptTokenAsInput() throws {
    let reply = Data(#"{"choices":[{"message":{"content":"{}"}}],"usage":{"prompt_tokens":10,"completion_tokens":4}}"#.utf8)
    #expect(try OpenAICompatibleClient.parse(reply).usage == TagVerificationUsage(inputTokens: 10, outputTokens: 4))
}

// MARK: - Options, estimate, and log

private func openAIOptions(model: String = "gpt-6.1-sol", baseURL: String? = nil) -> AITagVerificationService.Options {
    let defaults = TestDefaults.inMemory()
    defaults.set(model, forKey: OpenAICompatibleClient.modelDefaultsKey)
    if let baseURL {
        defaults.set(baseURL, forKey: OpenAICompatibleClient.baseURLDefaultsKey)
    }
    var options = AITagVerificationService.Options()
    options.provider = .openAICompatible
    return options.withCompatibleSettings(userDefaults: defaults)
}

@Test func compatibleSettingsFillTheModelAndItsPrice() {
    let options = openAIOptions()
    #expect(options.modelName == "gpt-6.1-sol")
    #expect(options.pricing == OpenAIModel.sol.pricing)

    // An Anthropic run is untouched and priced by its Claude model.
    let claude = AITagVerificationService.Options(model: .haiku45).withCompatibleSettings(userDefaults: TestDefaults.inMemory())
    #expect(claude.modelName == "claude-haiku-4-5")
    #expect(claude.pricing == ClaudeModel.haiku45.pricing)
    #expect(claude.compatibleModelName == nil)
}

@Test func anOpenAIRunIsEstimatedAsOnePassWithNoSearch() {
    // Search is on in the options, but this provider can't search, so there
    // is no second pass and no search fee to charge for.
    let options = openAIOptions()
    #expect(options.useWebSearch)
    // 100 × (2,600 × $2 + 1,220 × $10) / 1M.
    #expect(abs(AITagVerificationService.estimatedCost(trackCount: 100, options: options) - 1.74) < 0.0001)
    let text = AITagVerificationService.estimatedCostText(trackCount: 100, options: options)
    #expect(text == "about $1.74")
}

@Test func anUnpricedOrLocalModelSaysSoInsteadOfQuotingZero() {
    let unknown = openAIOptions(model: "mistral-large-latest", baseURL: "https://api.mistral.ai/v1")
    #expect(AITagVerificationService.estimatedCostText(trackCount: 100, options: unknown).contains("its own rates"))

    let local = openAIOptions(model: "llama3.1", baseURL: "http://localhost:11434/v1")
    #expect(AITagVerificationService.estimatedCostText(trackCount: 100, options: local).contains("free"))
}

@Test func anOpenAIRunIsLoggedWithItsModelAndCost() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("OpenAILogTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let log = try #require(TagVerificationRunLog.start(
        engine: .cloudModel, cloudOptions: openAIOptions(model: "gpt-6-luna"),
        trackCount: 1, selectionCount: 1, in: directory
    ))
    let track = Track(
        seratoStoredPath: "Music/A.mp3", fileURL: URL(fileURLWithPath: "/Music/A.mp3"),
        title: "A", artist: "B", album: "C", genre: "D", comment: "", year: 2020
    )
    log.record(
        TrackTagVerification(
            track: track, engineName: "gpt-6-luna", identityConfidence: 0.9, identitySummary: "",
            fields: [], usage: TagVerificationUsage(inputTokens: 1_000_000, outputTokens: 1_000_000)
        ),
        preselected: []
    )

    let lines = try String(contentsOf: log.fileURL, encoding: .utf8).split(separator: "\n").map {
        try #require(try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
    }
    #expect(lines[0]["provider"] as? String == "openAICompatible")
    #expect(lines[0]["model"] as? String == "gpt-6-luna")
    // A million in at $0.10 and a million out at $0.50.
    #expect(abs((lines[1]["costUSD"] as? Double ?? 0) - 0.60) < 0.000001)
}
