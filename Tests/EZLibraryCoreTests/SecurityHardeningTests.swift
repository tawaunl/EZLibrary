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

// MARK: - ffmpeg post-processor argument quoting
//
// yt-dlp splits `--postprocessor-args` with POSIX shlex before handing the
// pieces to ffmpeg. The values are track metadata, which arrives from YouTube
// titles and online lookups, so they are attacker-influenced. The old code
// wrapped them in double quotes and escaped `"` — but shlex unescapes `\\`
// inside double quotes, so a value ending in `\"` closed the quoted run and
// everything after it became new ffmpeg arguments.

@Test func metadataValuesCannotEscapeTheirQuotedArgument() {
    // The payload that used to break out: `\"` ends the quoted run, the rest
    // becomes argv, and `-y <path>` makes ffmpeg overwrite a chosen file.
    let hostile = #"Song\" -metadata comment=PWNED -y /tmp/pwned.mp3 \""#
    let quoted = YouTubeAudioImportService.shellQuotedForPostprocessor("title=\(hostile)")

    // Single quotes make every character literal, and the value contains none.
    #expect(quoted == "'title=\(hostile)'")
    #expect(quoted.hasPrefix("'"))
    #expect(quoted.hasSuffix("'"))
    // Exactly the opening and closing quote — no interior quote to break on.
    #expect(quoted.filter { $0 == "'" }.count == 2)
}

@Test func embeddedSingleQuotesAreEscapedNotDropped() {
    // A real-world apostrophe must survive, and must not end the quoted run.
    let quoted = YouTubeAudioImportService.shellQuotedForPostprocessor("title=Don't Stop")
    #expect(quoted == #"'title=Don'\''t Stop'"#)
}

@Test func metadataArgumentsQuoteEveryValue() {
    let metadata = SeratoTrackMetadataUpdate(
        title: #"Evil\" -y /tmp/pwned.mp3"#,
        artist: "Someone",
        album: "",
        genre: "",
        comment: "",
        key: "",
        bpm: nil,
        year: nil
    )
    let args = YouTubeAudioImportService.ffmpegMetadataArguments(metadata)

    // Every emitted value sits inside single quotes.
    #expect(args.contains("-metadata 'title="))
    #expect(args.contains("-metadata 'artist=Someone'"))
    // No bare double-quoted form survives anywhere.
    #expect(!args.contains("-metadata title=\""))
}

// MARK: - yt-dlp checksum manifest

@Test func ytDLPDigestIsReadFromTheChecksumManifest() {
    let manifest = """
    0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  yt-dlp
    fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210  yt-dlp_macos
    aaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccddddaaaabbbbccccdddd  yt-dlp.exe
    """
    #expect(
        YouTubeAudioImportService.expectedYTDLPDigest(fromChecksumManifest: manifest)
            == "fedcba9876543210fedcba9876543210fedcba9876543210fedcba9876543210"
    )
}

@Test func ytDLPDigestIsRejectedWhenMalformedOrAbsent() {
    #expect(YouTubeAudioImportService.expectedYTDLPDigest(fromChecksumManifest: "") == nil)
    // Right filename, digest is not 64 hex characters.
    #expect(YouTubeAudioImportService.expectedYTDLPDigest(fromChecksumManifest: "nothex  yt-dlp_macos") == nil)
    // Only other platforms listed.
    #expect(
        YouTubeAudioImportService.expectedYTDLPDigest(
            fromChecksumManifest: "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef  yt-dlp.exe"
        ) == nil
    )
}

// MARK: - Update download URL

@Test func updateDownloadURLMustBeHTTPSOnGitHub() throws {
    // The real shape of a release asset URL.
    try InstallerPackageVerifier.validateDownloadURL(
        #require(URL(string: "https://github.com/tawaunl/EZLibrary/releases/download/v1.0.7/EZLibrary-1.0.7.pkg"))
    )
    try InstallerPackageVerifier.validateDownloadURL(
        #require(URL(string: "https://objects.githubusercontent.com/some/asset.pkg"))
    )
}

@Test func updateDownloadURLRejectsCleartextAndForeignHosts() throws {
    #expect(throws: InstallerPackageVerifier.VerificationError.insecureDownloadURL("http")) {
        try InstallerPackageVerifier.validateDownloadURL(
            #require(URL(string: "http://github.com/tawaunl/EZLibrary/releases/download/v1/x.pkg"))
        )
    }
    #expect(throws: InstallerPackageVerifier.VerificationError.untrustedDownloadHost("evil.example.com")) {
        try InstallerPackageVerifier.validateDownloadURL(
            #require(URL(string: "https://evil.example.com/EZLibrary.pkg"))
        )
    }
    // A lookalike host that merely *contains* the allowed name.
    #expect(throws: InstallerPackageVerifier.VerificationError.untrustedDownloadHost("github.com.evil.example")) {
        try InstallerPackageVerifier.validateDownloadURL(
            #require(URL(string: "https://github.com.evil.example/EZLibrary.pkg"))
        )
    }
}

// MARK: - Package signature gate

private let signedByUs = """
Package "EZLibrary-1.0.7.pkg":
   Status: signed by a developer certificate issued by Apple for distribution
   Notarization: trusted by the Apple notary service
   Certificate Chain:
    1. Developer ID Installer: Tawaun Lucas (HMVH3CU559)
"""

@Test func aPackageSignedByThisProjectIsAccepted() throws {
    try InstallerPackageVerifier.checkSignatureOutput(signedByUs, expectedTeam: "HMVH3CU559")
}

@Test func anUnsignedPackageIsRefused() {
    // `installer` would happily install this one, which is the whole point.
    let unsigned = """
    Package "EZLibrary-0.1.0.5.pkg":
       Status: no signature
    """
    #expect(throws: InstallerPackageVerifier.VerificationError.unsigned) {
        try InstallerPackageVerifier.checkSignatureOutput(unsigned, expectedTeam: "HMVH3CU559")
    }
}

@Test func aPackageFromAnotherDeveloperIsRefused() {
    let otherTeam = signedByUs.replacingOccurrences(of: "HMVH3CU559", with: "ATTACKER99")
    #expect(throws: InstallerPackageVerifier.VerificationError.wrongTeam(found: "ATTACKER99")) {
        try InstallerPackageVerifier.checkSignatureOutput(otherTeam, expectedTeam: "HMVH3CU559")
    }
}

@Test func aSelfSignedPackageIsRefused() {
    let selfSigned = """
    Package "EZLibrary.pkg":
       Status: signed by untrusted certificate
       Certificate Chain:
        1. Developer ID Installer: Tawaun Lucas (HMVH3CU559)
    """
    #expect(throws: InstallerPackageVerifier.VerificationError.unsigned) {
        try InstallerPackageVerifier.checkSignatureOutput(selfSigned, expectedTeam: "HMVH3CU559")
    }
}

// MARK: - Credential storage

@Test func aKeySavedByAnOlderBuildIsStillReadableBeforeMigration() {
    let defaults = TestDefaults.inMemory()
    let store = InMemoryCredentialStore()
    defaults.set("sk-ant-legacy", forKey: ClaudeAPIClient.apiKeyDefaultsKey)

    #expect(ClaudeAPIClient.apiKey(environment: [:], userDefaults: defaults, credentials: store) == "sk-ant-legacy")
}

@Test func readingAKeyNeverWritesAnywhere() {
    // Reading used to migrate as a side effect, so any code path that wanted a
    // token — a test included — wrote to the real login keychain.
    let defaults = TestDefaults.inMemory()
    let store = InMemoryCredentialStore()
    defaults.set("sk-ant-legacy", forKey: ClaudeAPIClient.apiKeyDefaultsKey)

    _ = ClaudeAPIClient.apiKey(environment: [:], userDefaults: defaults, credentials: store)

    #expect(store.value(for: ClaudeAPIClient.apiKeyCredentialAccount) == nil)
    #expect(defaults.string(forKey: ClaudeAPIClient.apiKeyDefaultsKey) == "sk-ant-legacy")
}

@Test func launchMigrationMovesEveryLegacyKeyIntoTheKeychain() {
    let defaults = TestDefaults.inMemory()
    let store = InMemoryCredentialStore()
    for entry in AppCredentials.legacyMigrations {
        defaults.set("value-for-\(entry.account)", forKey: entry.defaultsKey)
    }

    let migrated = AppCredentials.migrateLegacyCredentials(store: store, userDefaults: defaults)

    #expect(migrated == AppCredentials.legacyMigrations.count)
    for entry in AppCredentials.legacyMigrations {
        #expect(store.value(for: entry.account) == "value-for-\(entry.account)")
        // No longer sitting in cleartext in the preferences plist.
        #expect(defaults.string(forKey: entry.defaultsKey) == nil)
    }
}

@Test func migrationIsIdempotentAndKeepsTheKeychainValue() {
    let defaults = TestDefaults.inMemory()
    let store = InMemoryCredentialStore(["anthropic-api-key": "sk-ant-current"])
    defaults.set("sk-ant-stale", forKey: ClaudeAPIClient.apiKeyDefaultsKey)

    AppCredentials.migrateLegacyCredentials(store: store, userDefaults: defaults)

    // The keychain copy wins; the stale plist copy is dropped either way.
    #expect(store.value(for: "anthropic-api-key") == "sk-ant-current")
    #expect(defaults.string(forKey: ClaudeAPIClient.apiKeyDefaultsKey) == nil)
    // A second pass changes nothing.
    #expect(AppCredentials.migrateLegacyCredentials(store: store, userDefaults: defaults) == 0)
}

@Test func savingAKeyNeverWritesItToUserDefaults() {
    let defaults = TestDefaults.inMemory()
    let store = InMemoryCredentialStore()

    ClaudeAPIClient.setAPIKey("sk-ant-new", userDefaults: defaults, credentials: store)

    #expect(store.value(for: ClaudeAPIClient.apiKeyCredentialAccount) == "sk-ant-new")
    #expect(defaults.string(forKey: ClaudeAPIClient.apiKeyDefaultsKey) == nil)
}

@Test func clearingAKeyRemovesItFromBothPlaces() {
    let defaults = TestDefaults.inMemory()
    let store = InMemoryCredentialStore(["anthropic-api-key": "sk-ant-old"])
    defaults.set("sk-ant-older", forKey: ClaudeAPIClient.apiKeyDefaultsKey)

    ClaudeAPIClient.setAPIKey(nil, userDefaults: defaults, credentials: store)

    #expect(store.value(for: ClaudeAPIClient.apiKeyCredentialAccount) == nil)
    #expect(defaults.string(forKey: ClaudeAPIClient.apiKeyDefaultsKey) == nil)
    #expect(ClaudeAPIClient.hasAPIKey(environment: [:], userDefaults: defaults, credentials: store) == false)
}

@Test func migrationLeavesTheLegacyCopyWhenTheKeychainWriteFails() {
    // If the keychain is unavailable, a key the user can still use beats a key
    // that silently disappeared.
    let defaults = TestDefaults.inMemory()
    let store = FailingCredentialStore()
    defaults.set("sk-ant-legacy", forKey: ClaudeAPIClient.apiKeyDefaultsKey)

    #expect(AppCredentials.migrateLegacyCredentials(store: store, userDefaults: defaults) == 0)
    #expect(defaults.string(forKey: ClaudeAPIClient.apiKeyDefaultsKey) == "sk-ant-legacy")
    #expect(ClaudeAPIClient.apiKey(environment: [:], userDefaults: defaults, credentials: store) == "sk-ant-legacy")
}

@Test func environmentKeysStillWinWhereTheyAlwaysDid() {
    let defaults = TestDefaults.inMemory()
    let store = InMemoryCredentialStore()
    // YouTube and Discogs have always preferred the environment over a saved key.
    let env = [OnlineTrackMetadataLookupService.youTubeAPIKeyEnvironmentKey: "env-key"]
    store.setValue("saved-key", for: OnlineTrackMetadataLookupService.youTubeAPIKeyCredentialAccount)

    #expect(
        OnlineTrackMetadataLookupService.youTubeAPIKey(
            environment: env, userDefaults: defaults, credentials: store
        ) == "env-key"
    )
}

/// A store whose writes never stick, standing in for an unavailable keychain.
private final class FailingCredentialStore: SecureCredentialStore, @unchecked Sendable {
    func value(for account: String) -> String? { nil }
    func setValue(_ value: String?, for account: String) {}
}
