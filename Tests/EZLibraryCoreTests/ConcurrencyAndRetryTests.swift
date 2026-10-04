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

// Several tracks run at once, so a rate-limited reply has to be waited out
// rather than failing the track.

/// Answers with the queued status codes in turn, then 200.
private final class StatusStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var statuses: [Int] = []
    nonisolated(unsafe) static var requestCount = 0
    private static let lock = NSLock()

    static func reset(statuses: [Int]) {
        lock.lock(); defer { lock.unlock() }
        self.statuses = statuses
        requestCount = 0
    }

    static var count: Int {
        lock.lock(); defer { lock.unlock() }
        return requestCount
    }

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}

    override func startLoading() {
        Self.lock.lock()
        let index = Self.requestCount
        Self.requestCount += 1
        let status = index < Self.statuses.count ? Self.statuses[index] : 200
        Self.lock.unlock()

        let body: [String: Any] = status == 200
            ? ["choices": [["message": ["content": "{\"ok\":true}"]]],
               "usage": ["prompt_tokens": 10, "completion_tokens": 5]]
            : ["error": ["message": "slow down"]]
        let data = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        let response = HTTPURLResponse(
            url: request.url!, statusCode: status, httpVersion: nil,
            headerFields: ["content-type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
}

private func stubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StatusStubProtocol.self]
    return URLSession(configuration: configuration)
}

private let configuration = OpenAICompatibleClient.Configuration(
    baseURL: "https://api.example.com/v1", model: "test-model", apiKey: "key"
)

@Suite(.serialized)
struct OpenAICompatibleRetryTests {
    init() { OpenAICompatibleClient.retryDelayScale = 0 }

    @Test func aRateLimitedReplyIsRetriedInsteadOfFailingTheTrack() async throws {
        StatusStubProtocol.reset(statuses: [429, 503])
        let response = try await OpenAICompatibleClient.send(
            system: "s", user: "u", configuration: configuration, session: stubSession()
        )
        #expect(response.text.contains("ok"))
        #expect(StatusStubProtocol.count == 3)
    }

    @Test func aKeyThatStaysThrottledStillReportsTheRateLimit() async {
        StatusStubProtocol.reset(statuses: Array(repeating: 429, count: 10))
        await #expect(throws: OpenAICompatibleClient.ClientError.self) {
            _ = try await OpenAICompatibleClient.send(
                system: "s", user: "u", configuration: configuration, session: stubSession()
            )
        }
        #expect(StatusStubProtocol.count == OpenAICompatibleClient.maxAttempts)
    }

    @Test func aRejectedKeyIsNotRetried() async {
        StatusStubProtocol.reset(statuses: [401])
        await #expect(throws: OpenAICompatibleClient.ClientError.self) {
            _ = try await OpenAICompatibleClient.send(
                system: "s", user: "u", configuration: configuration, session: stubSession()
            )
        }
        #expect(StatusStubProtocol.count == 1)
    }
}

// MARK: - How many tracks run at once

@Test func hostedCloudModelsRunFiveTracksAtOnce() {
    #expect(AITagVerificationService.Options().maxConcurrentTracks == 5)
}

@Test func aModelServerOnThisMacRunsTwoAtOnce() {
    let defaults = TestDefaults.inMemory()
    defaults.set("http://localhost:11434/v1", forKey: OpenAICompatibleClient.baseURLDefaultsKey)
    defaults.set("llama3.1", forKey: OpenAICompatibleClient.modelDefaultsKey)
    let options = AITagVerificationService.Options(provider: .openAICompatible)
        .withCompatibleSettings(userDefaults: defaults)
    #expect(options.maxConcurrentTracks == AITagVerificationService.Options.localModelConcurrentTracks)
}

#if canImport(FoundationModels)
@available(macOS 26.0, *)
@Test func theOnDeviceModelRunsTwoAtOnce() {
    // Measured: 49s for 12 tracks one at a time, 35s two at a time, no faster beyond.
    #expect(OnDeviceTagVerificationService.concurrentTracks == 2)
}
#endif
