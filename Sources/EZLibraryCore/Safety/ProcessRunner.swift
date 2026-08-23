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

/// Runs a child process without deadlocking on its output.
///
/// A `Pipe` is backed by a fixed OS buffer (64 KB on macOS). If the child
/// writes more than that and nobody is reading, the child blocks forever inside
/// `write()` — and a parent sitting in `waitUntilExit()` waits for a process
/// that can never finish. The app hangs with no error and nothing in the log.
///
/// This has bitten this codebase repeatedly (Homebrew, fpcalc, yt-dlp — all
/// verbose tools), so the correct sequence lives in one place:
///
/// 1. Start draining every captured pipe **before** waiting.
/// 2. Drain stdout and stderr **concurrently** — draining one to EOF while the
///    other fills its buffer deadlocks just as surely, only less often, which
///    makes it worse to diagnose.
/// 3. Only then `waitUntilExit()`.
///
/// Output you do not need should be `.discard`ed to `/dev/null` rather than
/// captured into a pipe nobody reads.
public enum ProcessRunner {
    /// What to do with one of the child's output streams.
    public enum OutputMode: Sendable {
        /// Read it fully into memory.
        case capture
        /// Send it to `/dev/null`. The safe choice for output nothing reads.
        case discard
    }

    public struct Result: Sendable {
        public let terminationStatus: Int32
        public let standardOutput: Data
        public let standardError: Data

        public var didSucceed: Bool { terminationStatus == 0 }

        public var outputText: String {
            String(data: standardOutput, encoding: .utf8) ?? ""
        }

        public var errorText: String {
            (String(data: standardError, encoding: .utf8) ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
        }

        public init(terminationStatus: Int32, standardOutput: Data, standardError: Data) {
            self.terminationStatus = terminationStatus
            self.standardOutput = standardOutput
            self.standardError = standardError
        }
    }

    /// Mutable buffer shared with a reader queue. Each box is written by
    /// exactly one queue and read only after that queue has finished, which the
    /// `DispatchGroup` guarantees.
    private final class Buffer: @unchecked Sendable {
        var data = Data()
    }

    public static func run(
        executableURL: URL,
        arguments: [String],
        environment: [String: String]? = nil,
        standardOutput: OutputMode = .capture,
        standardError: OutputMode = .capture
    ) throws -> Result {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = arguments
        if let environment {
            process.environment = environment
        }

        let outPipe = standardOutput == .capture ? Pipe() : nil
        let errPipe = standardError == .capture ? Pipe() : nil
        process.standardOutput = outPipe ?? FileHandle.nullDevice
        process.standardError = errPipe ?? FileHandle.nullDevice

        let outBuffer = Buffer()
        let errBuffer = Buffer()
        let group = DispatchGroup()
        let queue = DispatchQueue(label: "com.ezlibrary.processrunner", attributes: .concurrent)

        try process.run()

        if let outPipe {
            group.enter()
            queue.async {
                outBuffer.data = outPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }
        if let errPipe {
            group.enter()
            queue.async {
                errBuffer.data = errPipe.fileHandleForReading.readDataToEndOfFile()
                group.leave()
            }
        }

        // Both readers run to EOF, which happens when the child exits and its
        // write ends close. Only once the pipes are drained is it safe to wait.
        group.wait()
        process.waitUntilExit()

        return Result(
            terminationStatus: process.terminationStatus,
            standardOutput: outBuffer.data,
            standardError: errBuffer.data
        )
    }
}
