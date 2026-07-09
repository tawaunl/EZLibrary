# SeratoTools

SeratoTools is a native macOS toolkit for DJs who want a cleaner, safer, and more reliable Serato library.

From broken file paths to crate organization to bulk metadata cleanup, SeratoTools helps you spend less time fixing your library and more time playing music.

## Why DJs Use SeratoTools

- Recover missing tracks and repair moved files
- Build and manage crates faster
- Import new music with less manual busywork
- Batch-fix metadata for cleaner browsing and searching
- Consolidate scattered libraries without breaking references
- Run safer write operations with backup and atomic update patterns

## Product Surfaces

| Module | What it does |
|---|---|
| SeratoToolsApp | Visual workflows for tracks, crates, matching, backup, and consolidation |
| SeratoToolsCLI | Scriptable import flow for fast ingestion and crate assignment |
| SeratoToolsCore | Shared parsers, writers, and safety-focused data operations |

## Feature Highlights

### Tracks Workspace

- Browse your library and inspect track metadata
- Perform quick actions with confirmation controls
- Edit metadata with online lookup and fingerprint-assisted suggestions

### PlaylistMatch

- Paste Spotify playlist URLs, CSV rows, or plain text track lists
- Match against your Serato collection with confidence scoring and version selection
- Create crates from confirmed matches
- Keep unresolved entries in a Plan queue and resolve with YouTube-assisted flows

### Add Music

- Import files and folders into your destination music directory
- Move or copy mode based on your workflow
- Auto-discover supported audio formats recursively
- Create a dated crate, target an existing crate, or import without crate assignment

### YouTube Rip

- Process one or many links in a single batch
- Download audio with yt-dlp and ffmpeg integration
- Route output into crates and your main music location
- Control format, quality, bitrate, and metadata behavior

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
swift run SeratoTools
```

### Check CLI

```bash
swift run SeratoToolsCLI --help
```

## CLI Example

```bash
swift run SeratoToolsCLI \
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
/Applications/SeratoTools.app/Contents/Resources/scripts/install-finder-quick-action.sh
```

Environment controls:

- SERATOTOOLS_ADD_MODE
- SERATOTOOLS_ADD_DESTINATION
- SERATOTOOLS_ADD_CRATE_PREFIX
- SERATOTOOLS_LIBRARY_DIR

## Safety and Reliability

SeratoTools is built to reduce risk during library mutation.

- Explicit user actions for sensitive operations
- No silent auto-repair in missing-track workflows
- Backup plus atomic-write patterns in core services
- User-readable LocalizedError messages for recovery guidance

## Requirements

- macOS 14+
- Swift 6
- yt-dlp and ffmpeg for YouTube workflows
- fpcalc for audio fingerprint lookup
- Optional: SERATOTOOLS_DISCOGS_TOKEN
- Optional: SERATOTOOLS_ACOUSTID_KEY

## Test

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

Build universal2 package (Apple Silicon + Intel):

```bash
SERATOTOOLS_BUILD_UNIVERSAL=1 ./Scripts/build-installer.sh
```

Artifacts are written to dist/.

Installer note:

- Runtime dependencies are bundled inside the app (fpcalc, yt-dlp, ffmpeg, ffprobe, plus required non-system dylibs), so target machines do not need Homebrew dependency provisioning.

## Project Layout

- Sources/SeratoToolsApp/
- Sources/SeratoToolsCLI/
- Sources/SeratoToolsCore/
- Scripts/
- docs/
- Tests/SeratoToolsCoreTests/

## Docs

- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)
- [docs/ROADMAP.md](docs/ROADMAP.md)
- [docs/PACKAGING_STANDALONE.md](docs/PACKAGING_STANDALONE.md)
- [docs/FINDER_QUICK_ACTION_ADD_MUSIC.md](docs/FINDER_QUICK_ACTION_ADD_MUSIC.md)
- [docs/ENGINEERING_RULES.md](docs/ENGINEERING_RULES.md)

## Need Help?

Start with the troubleshooting Q and A guide:

- [docs/TROUBLESHOOTING.md](docs/TROUBLESHOOTING.md)

## Status

Active development focused on practical DJ utility, safer data mutation, and polished workflow UX.
