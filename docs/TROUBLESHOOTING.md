# SeratoTools Troubleshooting

This guide covers the most common setup, build, packaging, and runtime issues.

## Quick Triage Checklist

Before deep debugging, verify these basics:

1. Confirm you are on macOS 14 or newer.
2. Run `swift --version` and ensure Swift 6 is available.
3. Build once from repo root with `swift build`.
4. If using YouTube features, verify dependencies:
   - `command -v yt-dlp`
   - `command -v ffmpeg`
5. If using fingerprint lookup, verify:
   - `command -v fpcalc`
6. Confirm your Serato library path is valid (`database V2` exists in `_Serato_`).

## Build and Launch

## Q: `swift build` fails. What should I check first?

A: Confirm toolchain and working directory first.

- Run `swift --version`.
- Ensure you are at repository root (same folder as `Package.swift`).
- Re-run with verbose output: `swift build -v`.
- If errors mention missing modules or SDK mismatches, update Xcode Command Line Tools.

## Q: The GUI app builds but crashes shortly after launch. What can I do?

A: There is a documented unresolved UI-layer crash investigation for some environments.

- Review [CRASH_INVESTIGATION.md](CRASH_INVESTIGATION.md).
- Check crash reports in `~/Library/Logs/DiagnosticReports/`.
- Test with an empty library override to separate data issues from UI composition issues:
  - `SERATOTOOLS_LIBRARY_DIR=/tmp/nonexistent-empty-serato-dir swift run SeratoTools`

## Q: `swift run SeratoTools` does not open normally like an app.

A: Use packaged app flow for a normal app bundle experience.

- Build app bundle: `./Scripts/build-app.sh`
- Launch bundled app from `dist/SeratoTools.app`

## Library Location and Paths

## Q: SeratoTools is reading the wrong library. How do I force the path?

A: Set the explicit library override.

- Environment variable: `SERATOTOOLS_LIBRARY_DIR`
- Point it at your `_Serato_` directory (the folder that contains `database V2`).

Example:

```bash
SERATOTOOLS_LIBRARY_DIR="/Volumes/YourDrive/_Serato_" swift run SeratoTools
```

## Q: I get errors about missing `database V2`.

A: The selected path is not a valid Serato library root.

- Verify the folder contains `database V2`.
- If this is a new system, open Serato once so it initializes library files.
- Retry with explicit `SERATOTOOLS_LIBRARY_DIR`.

## Q: My tracks are on an external drive and paths seem inconsistent.

A: Ensure the external volume is mounted before launching SeratoTools.

- Confirm the drive appears under `/Volumes`.
- Confirm expected audio file paths exist.
- Re-run operations after mount; path resolver logic prefers existing matches.

## Finder Quick Action

## Q: The Finder Quick Action does not appear.

A: Reinstall and relaunch Finder.

- Install: `./Scripts/install-finder-quick-action.sh`
- Relaunch Finder if needed.
- Verify workflow exists at:
  - `~/Library/Services/Add To Serato Library.workflow`

## Q: Finder Quick Action runs but does not import as expected.

A: Validate configuration and inputs.

- Confirm selected files are supported audio formats.
- Check environment settings:
  - `SERATOTOOLS_ADD_MODE`
  - `SERATOTOOLS_ADD_DESTINATION`
  - `SERATOTOOLS_ADD_CRATE_PREFIX`
  - `SERATOTOOLS_LIBRARY_DIR`
- Test equivalent direct CLI command to isolate Finder workflow issues.

## Q: What formats are supported by Add Music imports?

A: Supported formats are:

- `mp3`, `m4a`, `aac`, `wav`, `aif`, `aiff`, `flac`, `alac`, `ogg`

## YouTube and Metadata Features

## Q: YouTube Rip says dependencies are missing.

A: Install required binaries and retry.

- Required: `yt-dlp` and `ffmpeg`
- If Homebrew is installed:
  - `brew install yt-dlp ffmpeg`

## Q: Fingerprint lookup is unavailable.

A: Ensure `fpcalc` and API key are configured.

- Install `fpcalc` (Chromaprint tool).
- Set `SERATOTOOLS_ACOUSTID_KEY` or save key in app settings.
- Verify with `command -v fpcalc`.

## Q: Discogs lookup is failing.

A: Configure Discogs token.

- Set `SERATOTOOLS_DISCOGS_TOKEN`.
- Or store token in app settings if supported by your flow.

## Packaging and Installer

## Q: `build-app.sh` or `build-installer.sh` fails on dependency checks.

A: Make sure required tools are available.

- `fpcalc` and `ffmpeg` are required on the build machine and may be installed via Homebrew during build.
- `yt-dlp` portable binary is downloaded during build.

## Q: Universal build mode fails saying a dependency is not universal2.

A: Universal mode validates architecture slices for bundled runtime tools and dylibs.

- This commonly happens on Apple Silicon when only arm64 Homebrew dependencies are installed.
- Ensure Intel-side dependencies are also available on the build host.
- Retry after provisioning toolchains/dependencies for both architectures.

## Q: Does the pkg installer install dependencies on the target machine?

A: No. The app is packaged with required runtime dependencies already bundled.

- Bundled: `fpcalc`, `yt-dlp`, `ffmpeg`, `ffprobe`
- Bundled: required non-system dynamic libraries for these tools
- Target machine does not need Homebrew to run these features

## Q: I installed the app but Quick Action is still missing.

A: Install Quick Action from bundled script after app install.

```bash
/Applications/SeratoTools.app/Contents/Resources/scripts/install-finder-quick-action.sh
```

## Q: How do I produce a signed installer package?

A: Pass Developer ID Installer identity to packaging script.

```bash
SERATOTOOLS_PKG_SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" ./Scripts/build-installer.sh
```

## Runtime Behavior and Safety

## Q: A write operation failed. Where should I look first?

A: Start with user-facing error message, then verify path and permissions.

- Confirm destination and library paths are writable.
- Confirm source files still exist.
- Retry after ensuring external drives are mounted.
- Re-run with smaller scope to isolate a single problematic file.

## Q: Is it safe to run library-changing operations while Serato is open?

A: Some workflows support active Serato sessions, but safest practice is:

- Close Serato for high-volume rewrite or consolidation operations.
- Keep backups current before bulk mutation.

## Q: How can I recover quickly if an operation did not produce expected results?

A: Use backup-first workflow and incremental verification.

- Use Backup mode before major changes.
- Validate a small subset first.
- Keep operation scope small until behavior matches expectations.

## Testing and Developer Notes

## Q: `swift test` behaves unexpectedly in my environment.

A: Command Line Tools-only setups may differ from full Xcode environments.

- Run `swift test -v` for diagnostics.
- If needed, validate key flows through targeted manual runs and fixture-based checks.

## Q: `rg` command is missing when following dev instructions.

A: Install ripgrep or use fallback tools.

- Install with Homebrew: `brew install ripgrep`
- Fallbacks: `grep`, `find`, or editor search tools.

## Still Stuck?

If none of the above solves your issue:

1. Capture exact command used.
2. Capture full error output.
3. Note your library path and whether it is on external storage.
4. Include macOS version and `swift --version`.
5. Open an issue with reproduction steps and expected versus actual behavior.
