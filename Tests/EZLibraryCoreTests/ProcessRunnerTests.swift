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

private let shell = URL(fileURLWithPath: "/bin/sh")

/// Every test here carries a time limit on purpose. The bug this guards against
/// is a deadlock, and a deadlocked test hangs the whole suite forever instead of
/// failing — the time limit turns a regression back into a normal red test.

@Test(.timeLimit(.minutes(1)))
func outputLargerThanThePipeBufferDoesNotDeadlock() throws {
    // 512 KB, eight times the 64 KB pipe buffer. Under the old
    // wait-then-read order this call never returns.
    let result = try ProcessRunner.run(
        executableURL: shell,
        arguments: ["-c", "LC_ALL=C /usr/bin/head -c 524288 /dev/zero | /usr/bin/tr '\\0' 'x'"]
    )

    #expect(result.didSucceed)
    #expect(result.standardOutput.count == 524_288)
}

@Test(.timeLimit(.minutes(1)))
func largeOutputOnBothStreamsAtOnceDoesNotDeadlock() throws {
    // Draining stdout to EOF first and stderr afterwards deadlocks just as
    // surely when stderr fills while stdout is still being read. Both streams
    // are oversized here, so only concurrent draining survives.
    let script = """
    LC_ALL=C /usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\0' 'o'
    LC_ALL=C /usr/bin/head -c 300000 /dev/zero | /usr/bin/tr '\\0' 'e' >&2
    """
    let result = try ProcessRunner.run(executableURL: shell, arguments: ["-c", script])

    #expect(result.didSucceed)
    #expect(result.standardOutput.count == 300_000)
    #expect(result.standardError.count == 300_000)
}

@Test(.timeLimit(.minutes(1)))
func discardedOutputIsNotCapturedAndStillDoesNotDeadlock() throws {
    let result = try ProcessRunner.run(
        executableURL: shell,
        arguments: ["-c", "LC_ALL=C /usr/bin/head -c 524288 /dev/zero | /usr/bin/tr '\\0' 'x'; echo problem >&2"],
        standardOutput: .discard
    )

    #expect(result.didSucceed)
    #expect(result.standardOutput.isEmpty)
    #expect(result.errorText == "problem")
}

@Test func exitStatusAndStderrAreReportedOnFailure() throws {
    let result = try ProcessRunner.run(
        executableURL: shell,
        arguments: ["-c", "echo 'it broke' >&2; exit 3"]
    )

    #expect(!result.didSucceed)
    #expect(result.terminationStatus == 3)
    #expect(result.errorText == "it broke")
}

@Test func outputTextDecodesCapturedBytes() throws {
    let result = try ProcessRunner.run(executableURL: shell, arguments: ["-c", "echo hello"])
    #expect(result.outputText.trimmingCharacters(in: .whitespacesAndNewlines) == "hello")
}

@Test func environmentIsPassedThroughToTheChild() throws {
    let result = try ProcessRunner.run(
        executableURL: shell,
        arguments: ["-c", "echo \"$EZLIBRARY_TEST_VALUE\""],
        environment: ["EZLIBRARY_TEST_VALUE": "passed"]
    )
    #expect(result.outputText.trimmingCharacters(in: .whitespacesAndNewlines) == "passed")
}

@Test func launchingAMissingExecutableThrows() {
    #expect(throws: (any Error).self) {
        try ProcessRunner.run(
            executableURL: URL(fileURLWithPath: "/nonexistent/definitely-not-here"),
            arguments: []
        )
    }
}
