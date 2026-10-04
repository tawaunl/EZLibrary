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

### Every release also updates the public site

`Scripts/release.sh` publishes the `.pkg` to GitHub Releases, but it does **not**
touch `site/`. Do that as part of the same change, before pushing:

1. Add an entry to [docs/CHANGELOG.md](docs/CHANGELOG.md) under the new version heading — this is what `release.sh` copies verbatim into the GitHub release notes.
2. Bump the hardcoded fallback version/release-count in [site/index.html](site/index.html) (`data-latest-version`, the "public releases" stat) — the live lookup overwrites these at runtime, but they're what shows before JS runs or if GitHub is unreachable.
3. **If a change is major enough to be a headline feature** (not a bugfix or small tweak), give it a feature card:
   - Add an entry to the `FEATURES` table in [Scripts/build-site-pages.py](Scripts/build-site-pages.py) — this generates both the card on [site/features/index.html](site/features/index.html) and its own page at `site/features/<slug>.html`.
   - Regenerate and commit the output: `./Scripts/build-site-pages.py`. CI (`pages.yml`) re-runs this script and **fails the deploy** if `site/features/` doesn't match, so never hand-edit those generated files.
4. Minor changes don't need a new feature card — the changelog entry is enough.

Site deploy is automatic: `pages.yml` runs on every push to `main` that touches `site/**`.
