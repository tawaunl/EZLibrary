# EZLibrary

<p align="center">
  <img src="docs/files/ezlibrary_icon_glow_gold.png" alt="EZLibrary app icon" width="160" height="160">
</p>

<p align="center">
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-GPLv3-blue.svg" alt="License: GPL v3"></a>
  <a href="https://github.com/tawaunl/EZLibrary/actions/workflows/ci.yml"><img src="https://github.com/tawaunl/EZLibrary/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <img src="https://img.shields.io/badge/platform-macOS%2014%2B-lightgrey.svg" alt="Platform: macOS 14+">
  <img src="https://img.shields.io/badge/Swift-6-orange.svg" alt="Swift 6">
  <img src="https://img.shields.io/badge/tests-100%2B-success.svg" alt="100+ tests">
  <img src="https://img.shields.io/badge/maintained-yes-brightgreen.svg" alt="Maintained: yes">
  <a href="CONTRIBUTING.md"><img src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" alt="PRs welcome"></a>
</p>

> EZLibrary is free and open source software for DJs and hobbyists. Anyone is welcome to use it, study it, share it, and improve it under the terms of the [GNU GPL v3](LICENSE).

> EZLibrary is an independent, community-built utility. It isn't affiliated with, endorsed by, or sponsored by Serato Audio Research or any other music platform referenced in this project. "Serato" is a trademark of its respective owner. This tool reads and writes Serato's library file format for interoperability purposes only.

EZLibrary is a native macOS toolkit for DJs who want a cleaner, safer, and more reliable Serato library.

From broken file paths to crate organization to bulk metadata cleanup, EZLibrary helps you spend less time fixing your library and more time playing music.

## Why DJs Use EZLibrary

- Recover missing tracks and repair moved files
- Build and manage crates faster
- Import new music with less manual busywork
- Batch-fix metadata for cleaner browsing and searching
- Consolidate scattered libraries without breaking references
- Run safer write operations with backup and atomic update patterns

## Why Trust EZLibrary

EZLibrary reads and writes your Serato library directly. Before you point any tool
at your crates, it's worth knowing who built it and how — and every claim here is
something you can verify in this repository.

**Not affiliated with Serato Audio Research.** EZLibrary is an independent project.
It isn't sponsored, endorsed, or reviewed by Serato. It reads and writes Serato's
library file format for interoperability purposes only.

**Real commit history, not a weekend drop.** Check the commit log yourself — this
project has grown incrementally across **150+ commits and 7 releases**, with
ongoing fixes, tests, and refactors, not a single large initial commit followed by
silence.

**Tested, not just tried.** The core parsing, writing, and safety logic lives in
`EZLibraryCore` and is covered by a real automated test suite (100+ tests) in
[Tests/EZLibraryCoreTests/](Tests/EZLibraryCoreTests). Run `swift test` yourself to
see what's checked, and it runs in CI on every push.

**Documented engineering standards.** See
[docs/ENGINEERING_RULES.md](docs/ENGINEERING_RULES.md) for the rules this project
holds itself to around safe data mutation, error handling, and review.

**Built for safe writes, not just fast ones.** Every operation that touches your
library — import, tag edit, consolidation, missing-track repair — runs through
backup-first and atomic-write patterns with read-back verification, so a failed
operation doesn't leave your crates half-written or corrupted. See
[docs/SECURITY_AND_DATA_HANDLING.md](docs/SECURITY_AND_DATA_HANDLING.md) for
specifics.

**Actively maintained.** 7 releases so far, with updates landing roughly monthly
(more often for fixes). Check the
[Releases](https://github.com/tawaunl/EZLibrary/releases) page and the
[changelog](docs/CHANGELOG.md) for the latest activity — not just a README that
hasn't been touched in months.

**Open where it counts.** The entire engine is open source and auditable under
[GPLv3](LICENSE). You don't have to trust a black box with your crates.

> There's been a real uptick in AI-generated DJ tools published with little to no
> commit history, no tests, and no long-term maintenance plan. Several have quietly
> become abandonware within months of release — a real risk when a tool has write
> access to your entire library. Before trusting any tool with your Serato data,
> check its commit history, test coverage, and how recently it's been updated.
> EZLibrary is built to hold up to that scrutiny.

## Product Surfaces

| Module | What it does |
|---|---|
| EZLibraryApp | Visual workflows for tracks, crates, matching, backup, and consolidation |
| EZLibraryCLI | Scriptable import flow for fast ingestion and crate assignment |
| EZLibraryCore | Shared parsers, writers, and safety-focused data operations |

## Feature Highlights

### Tracks Workspace

- Browse your library and inspect track metadata
- Perform quick actions with confirmation controls
- Edit metadata with online lookup and fingerprint-assisted suggestions

### PlaylistMatch

- Paste Spotify playlist URLs, CSV rows, or plain text track lists
- Match against your Serato collection with confidence scoring and version selection
- Create crates from confirmed matches
- Keep unresolved entries in a Plan queue for later resolution

### Add Music

- Import files and folders into your destination music directory
- Move or copy mode based on your workflow
- Auto-discover supported audio formats recursively
- Create a dated crate, target an existing crate, or import without crate assignment

### Crates

- Navigate regular and smart crate trees
- Filter and inspect crate contents quickly
- Use crate-centric track operations and stats

### Tags Bulk Edit

- Edit Artist, Genre, and Year across All Tracks or selected crate scopes
- Use Only Fill Empty to protect existing metadata
- Track completion quality with scope vs global baseline metrics

### Missing Tracks

- Identify unresolved file references
- Find likely moved/renamed candidates
- Apply explicit per-track fixes
- Build a review crate for unresolved items

### Backup

- Generate timestamped backups in SeratoBackups
- Use full, incremental, or single-crate modes
- Preview size and count estimates before committing

### Library Consolidation

- Map fragmented source folders across your collection
- Move or copy into a single destination
- Rewrite Serato paths so crates and references remain valid
- Select source groups and validate destination capacity first

## Quick Start

### Build

```bash
swift build
```

### Launch App

```bash
swift run EZLibrary
```

### Check CLI

```bash
swift run EZLibraryCLI --help
```

## CLI Example

```bash
swift run EZLibraryCLI \
  --mode move \
  --destination "$HOME/Music" \
  --crate-prefix "New Music" \
  -- ~/Downloads/incoming ~/Desktop/track.mp3
```

CLI options:

- -d, --destination <path>
- -c, --crate-prefix <name>
- -m, --mode <move|copy>
- -l, --library-dir <path>
- -h, --help

## Finder Quick Action

Install from source checkout:

```bash
./Scripts/install-finder-quick-action.sh
```

Install from packaged app:

```bash
/Applications/EZLibrary.app/Contents/Resources/scripts/install-finder-quick-action.sh
```

Environment controls:

- EZLIBRARY_ADD_MODE
- EZLIBRARY_ADD_DESTINATION
- EZLIBRARY_ADD_CRATE_PREFIX
- EZLIBRARY_LIBRARY_DIR

## Safety and Reliability

EZLibrary is built to reduce risk during library mutation.

- Explicit user actions for sensitive operations
- No silent auto-repair in missing-track workflows
- Automatic timestamped snapshot of every Serato file **before** it is written
- Atomic writes (temp-file-then-rename) so a crash can't corrupt `database V2`
- Read-back verification after metadata writes, with rollback on failure
- Refuses to write while Serato is running to avoid clobbered edits
- User-readable LocalizedError messages for recovery guidance

For a detailed, code-referenced explanation of what gets backed up, what is
atomic, and what happens if a write fails midway, see
**[docs/SECURITY_AND_DATA_HANDLING.md](docs/SECURITY_AND_DATA_HANDLING.md)**.

## Requirements

- macOS 13+
- Apple Silicon or Intel (shipped app is universal2)
- Swift 6
- ffmpeg for audio processing
- fpcalc for audio fingerprint lookup
- Optional: EZLIBRARY_DISCOGS_TOKEN
- Optional: EZLIBRARY_ACOUSTID_KEY

## Test

EZLibrary ships with a real automated test suite — 100+ tests across 18 suites in
[Tests/EZLibraryCoreTests/](Tests/EZLibraryCoreTests) — covering the Serato format
parsers/writers, the backup and atomic-write safety layer, and the core services.
Tests are offline and deterministic.

```bash
swift test
```

## Packaging

Build app bundle:

```bash
./Scripts/build-app.sh
```

Build installer package:

```bash
./Scripts/build-installer.sh
```

Artifacts are written to dist/.

Architecture:

- The app and CLI binaries are **always built universal2 (arm64 + x86_64)**, so the shipped app installs and launches on both Apple Silicon and Intel Macs. (An arm64-only app makes Intel Macs report *"This application is not supported on this Mac."*)
- `EZLIBRARY_BUILD_UNIVERSAL=1` additionally requires the bundled runtime tools (fpcalc/ffmpeg/ffprobe) to be universal2, and validates this with a preflight. It needs universal Homebrew dependencies on the build host.

  ```bash
  EZLIBRARY_BUILD_UNIVERSAL=1 ./Scripts/build-installer.sh
  ```

Installer note:

- Runtime dependencies are bundled inside the app (fpcalc, ffmpeg, ffprobe, plus required non-system dylibs), so target machines do not need Homebrew dependency provisioning. Without `EZLIBRARY_BUILD_UNIVERSAL=1`, the bundled tools are the build host's native architecture; on a different-arch Mac the installer's Homebrew bootstrap installs arch-correct copies at install time.

## Project Layout

- Sources/EZLibraryApp/
- Sources/EZLibraryCLI/
- Sources/EZLibraryCore/
- Scripts/
- docs/
- Tests/EZLibraryCoreTests/

## Docs

- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- [docs/SECURITY_AND_DATA_HANDLING.md](docs/SECURITY_AND_DATA_HANDLING.md)
- [docs/CHANGELOG.md](docs/CHANGELOG.md)
- [docs/ROADMAP.md](docs/ROADMAP.md)
- [docs/PACKAGING_STANDALONE.md](docs/PACKAGING_STANDALONE.md)
- [docs/FINDER_QUICK_ACTION_ADD_MUSIC.md](docs/FINDER_QUICK_ACTION_ADD_MUSIC.md)
- [docs/ENGINEERING_RULES.md](docs/ENGINEERING_RULES.md)
- [SECURITY.md](SECURITY.md)

## Need Help?

Start with the troubleshooting Q and A guide:

- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

## Maintenance and Support

EZLibrary is actively maintained, with new releases landing roughly monthly (more
often for fixes). Progress is tracked in the open:

- **What changed and when:** [docs/CHANGELOG.md](docs/CHANGELOG.md)
- **What's planned:** [docs/ROADMAP.md](docs/ROADMAP.md)
- **Report a bug or request a feature:** [open an issue](https://github.com/tawaunl/EZLibrary/issues/new/choose)
- **Report a security or data-loss issue:** [SECURITY.md](SECURITY.md)

Data-integrity and security issues are the highest priority in the tracker.

## Contributing

EZLibrary is community-driven, and contributions from DJs and hobbyists are welcome —
whether that's a bug report, a feature idea, docs, or code.

- Read the [Contributing Guide](CONTRIBUTING.md) to get started.
- Review our [Code of Conduct](CODE_OF_CONDUCT.md).
- Open an [issue](https://github.com/tawaunl/EZLibrary/issues/new/choose) or pull request.

## License

EZLibrary is free and open source software licensed under the
[GNU General Public License v3.0](LICENSE). You are free to use, study, share, and
modify it. If you distribute a modified version, you must also release your changes
under the GPL v3 so the community can keep benefiting from them.

## Status

Active development focused on practical DJ utility, safer data mutation, and polished workflow UX.
