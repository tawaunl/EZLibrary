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

/// Gatekeeping for the self-update path.
///
/// The updater hands a downloaded `.pkg` to `installer -target /` under
/// `with administrator privileges`, so whatever arrives in that file runs as
/// root. `installer` itself does not require a signature — it will happily
/// install an unsigned package — which means the download is the whole trust
/// boundary. These checks make that boundary explicit:
///
/// 1. The asset URL must be HTTPS on a GitHub host, so a redirect or a
///    tampered release payload can't point the download somewhere else.
/// 2. The downloaded package must carry a Developer ID Installer signature
///    from this project's team before it is ever passed to `installer`.
public enum InstallerPackageVerifier {
    /// The Apple Developer team whose Developer ID Installer certificate signs
    /// every published EZLibrary package. Verified against the shipped
    /// installers in `dist/`.
    public static let expectedTeamIdentifier = "HMVH3CU559"

    /// Hosts GitHub serves release assets from.
    static let allowedDownloadHosts: Set<String> = [
        "github.com",
        "objects.githubusercontent.com",
        "release-assets.githubusercontent.com"
    ]

    public enum VerificationError: LocalizedError, Equatable {
        case insecureDownloadURL(String)
        case untrustedDownloadHost(String)
        case toolUnavailable
        case unsigned
        case wrongTeam(found: String)

        public var errorDescription: String? {
            switch self {
            case .insecureDownloadURL:
                return "The update download wasn't offered over a secure connection, so it was rejected."
            case .untrustedDownloadHost(let host):
                return "The update was hosted somewhere unexpected (\(host)), so it was rejected."
            case .toolUnavailable:
                return "EZLibrary couldn't verify the update's signature, so it wasn't installed."
            case .unsigned:
                return "The downloaded update isn't signed by a trusted developer certificate, so it wasn't installed."
            case .wrongTeam(let found):
                return "The downloaded update is signed by an unexpected developer (\(found)), so it wasn't installed."
            }
        }

        public var recoverySuggestion: String? {
            "Download the update from the release page instead, and report this if it keeps happening."
        }
    }

    /// Rejects a release asset URL that isn't HTTPS on a GitHub host.
    public static func validateDownloadURL(_ url: URL) throws {
        guard url.scheme?.lowercased() == "https" else {
            throw VerificationError.insecureDownloadURL(url.scheme ?? "none")
        }
        guard let host = url.host?.lowercased() else {
            throw VerificationError.untrustedDownloadHost("none")
        }
        let isAllowed = allowedDownloadHosts.contains(host)
            || allowedDownloadHosts.contains { host.hasSuffix("." + $0) }
        guard isAllowed else {
            throw VerificationError.untrustedDownloadHost(host)
        }
    }

    /// Runs `pkgutil --check-signature` and requires a Developer ID signature
    /// from `expectedTeamIdentifier`. Called before the package is handed to
    /// the privileged installer.
    public static func verifySignature(
        ofPackageAt url: URL,
        expectedTeam: String = expectedTeamIdentifier
    ) throws {
        let pkgutil = URL(fileURLWithPath: "/usr/sbin/pkgutil")
        guard FileManager.default.isExecutableFile(atPath: pkgutil.path) else {
            throw VerificationError.toolUnavailable
        }

        let result: ProcessRunner.Result
        do {
            result = try ProcessRunner.run(
                executableURL: pkgutil,
                arguments: ["--check-signature", url.path]
            )
        } catch {
            throw VerificationError.toolUnavailable
        }

        guard result.didSucceed else {
            throw VerificationError.unsigned
        }
        try checkSignatureOutput(result.outputText, expectedTeam: expectedTeam)
    }

    /// Parses `pkgutil --check-signature` output. Split out so the matching
    /// rules can be tested without a real signed package on disk.
    static func checkSignatureOutput(_ output: String, expectedTeam: String) throws {
        // pkgutil prints "Status: signed by a developer certificate issued by
        // Apple for distribution" for a Developer ID package. Anything else —
        // "no signature", a self-signed chain, an untrusted root — is refused.
        let status = output
            .split(separator: "\n")
            .first { $0.contains("Status:") }?
            .trimmingCharacters(in: .whitespaces) ?? ""

        guard status.contains("signed by a developer certificate issued by Apple") else {
            throw VerificationError.unsigned
        }

        // The leaf is printed as "Developer ID Installer: Name (TEAMID)".
        guard let leaf = output
            .split(separator: "\n")
            .first(where: { $0.contains("Developer ID Installer:") }) else {
            throw VerificationError.unsigned
        }

        guard leaf.contains("(" + expectedTeam + ")") else {
            let found = String(leaf)
                .split(separator: "(").last
                .map { String($0).replacingOccurrences(of: ")", with: "") }
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? "unknown"
            throw VerificationError.wrongTeam(found: found)
        }
    }
}
