# CLAUDE.md

Notes for Claude Code (and other AI agents) working in this repo. For general
contributor docs see [CONTRIBUTING.md](CONTRIBUTING.md) and
[docs/ENGINEERING_RULES.md](docs/ENGINEERING_RULES.md).

## Layout

- `Sources/EZLibraryCore` — library logic (Serato database/crate I/O, tagging, AI tag verification). Put new logic here, with tests.
- `Sources/EZLibraryApp` — SwiftUI macOS app (`swift run EZLibrary`).
- `Sources/EZLibraryCLI`, `Sources/EZLibraryBench` — CLI and benchmarks.
- `Tests/EZLibraryCoreTests` — the only test target.
- `Mobile/PocketCrates` — companion mobile app.
- `Scripts/` — app/installer build, notarize, release.

## Before you finish a change — match CI

CI (`.github/workflows/ci.yml`) runs two jobs. Run both locally:

```bash
/usr/bin/swift build --build-tests
/usr/bin/swift test --skip-build --no-parallel
swiftlint lint --quiet        # must exit 0 with no `error:` lines; warnings are OK
```

- Use `/usr/bin/swift`, not the `swift` that swiftly puts on PATH (it breaks builds here). For scripts: `PATH="/usr/bin:$PATH" Scripts/build-app.sh`.
- `--no-parallel` is required: some write-safety test seams are process-wide statics.
- Ignore XCTest's "Executed 0 tests" line; the Swift Testing results are the ones that count.

### SwiftLint: the error that keeps failing CI

`shorthand_operator` is an **error**, and it has broken CI repeatedly:

```swift
usage = usage + resultUsage   // ❌ fails CI
usage += resultUsage          // ✅
```

Always use `+=`, `-=`, `*=`, `/=`. If a custom type only defines `+`, add a
matching `static func +=` rather than writing the long form
(`TagVerificationUsage` already has one).

## Safety rules

- **Never touch the user's real Serato library.** Point runs at a disposable copy: `EZLIBRARY_LIBRARY_DIR="/tmp/_Serato_" swift run EZLibrary`. Keep the backup + atomic-write + verify pattern for anything that mutates a library.
- The user's real EZLibrary app is often running. Before any GUI automation, check `ps aux` and confirm you're driving the demo instance, not theirs.
- **Never call the live Anthropic API** from tests or scripts. Inject the API key / transport; an un-injected keychain lookup finds the real key and bills it.
- Tests that need `UserDefaults` must use `TestDefaults.inMemory()`. Named suites leak plists and read the user's real settings.
- Run subprocesses through `ProcessRunner` (`Sources/EZLibraryCore/Safety/ProcessRunner.swift`). Reading a `Pipe` after `waitUntilExit()` deadlocks on large output.

## Code conventions

- New user-facing errors conform to `LocalizedError` with a plain-language `errorDescription` (and `recoverySuggestion` when there's a next step).
- Keep tests offline and deterministic.
- Genre spelling is canonicalized (e.g. "Hip Hop"); go through `GenreCanonicalizer` instead of hard-coding spellings.

## Releases

- Always build universal: `EZLIBRARY_BUILD_UNIVERSAL=1`.
- Developer ID Application + Installer certs (team `HMVH3CU559`) are installed; the scripts pick the newest by SHA-1.
