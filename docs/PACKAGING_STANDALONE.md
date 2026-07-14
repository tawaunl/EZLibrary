# Standalone Packaging

This project can now be packaged as a self-contained macOS app + installer package.

## What gets bundled

- `SeratoTools.app`
- `SeratoToolsCLI` inside app resources
- `fpcalc` (required for AcoustID fingerprint lookup)
- `yt-dlp` and `ffmpeg` when available on the build machine
- Finder Quick Action helper scripts in app resources

Bundled tools are placed in:

- `SeratoTools.app/Contents/Resources/bin`

## Build app bundle

From repository root:

```bash
./Scripts/build-app.sh
```

Build universal2 app bundle (Apple Silicon + Intel):

```bash
SERATOTOOLS_BUILD_UNIVERSAL=1 ./Scripts/build-app.sh
```

Universal build note:

- The script validates that bundled runtime tools and libraries are universal2.
- Universal mode now performs a fast preflight before compile to fail early when required runtime tools are single-arch.
- If your build host only has single-arch Homebrew dependencies, universal mode fails with an actionable error.

Output:

- `dist/SeratoTools.app`

## Build installer package (.pkg)

From repository root:

```bash
./Scripts/build-installer.sh
```

Build universal2 installer package:

```bash
SERATOTOOLS_BUILD_UNIVERSAL=1 ./Scripts/build-installer.sh
```

Universal installer note:

- `build-installer.sh` delegates to `build-app.sh`, so the same universal dependency validation applies.

Output:

- `dist/SeratoTools-<version>.pkg`

Installer behavior on target machines:

- Removes quarantine attributes from `/Applications/SeratoTools.app` when present.
- Bootstraps runtime dependencies for the logged-in user on a fresh machine:
  installs Homebrew (if missing) plus `yt-dlp`, `ffmpeg`, and `chromaprint`
  (`fpcalc`). This runs best-effort and detached so it never blocks or fails the
  install — the app also ships portable copies of these tools, so it works even
  if the bootstrap can't run.
- The bootstrap is the bundled `Contents/Resources/scripts/install-dependencies.sh`.
  The postinstall runs it as root; the script re-targets the work to the console
  user (Homebrew must not run as root) and pre-stages the Homebrew prefix so the
  first install avoids an interactive password prompt where possible.
- Bootstrap progress is logged to `/tmp/seratotools-install-dependencies.log`
  (installer actions to `/tmp/seratotools-postinstall.log`).

Run the dependency bootstrap manually at any time:

```bash
/Applications/SeratoTools.app/Contents/Resources/scripts/install-dependencies.sh
```

The YouTube Rip screen also exposes an **Install Dependencies** button that runs
the same bootstrap on demand when `yt-dlp`/`ffmpeg` are missing.

Install locally for testing:

```bash
installer -pkg "dist/SeratoTools-<version>.pkg" -target /
```

## Optional: signed package

If you have a Developer ID Installer identity, provide it at build time:

```bash
SERATOTOOLS_PKG_SIGN_IDENTITY="Developer ID Installer: Your Name (TEAMID)" ./Scripts/build-installer.sh
```

## Quick Action after app install

After installing the app into `/Applications`, install Finder Quick Action:

```bash
/Applications/SeratoTools.app/Contents/Resources/scripts/install-finder-quick-action.sh
```

## Notes

- `fpcalc` is required and will be installed via Homebrew during build if missing.
- Runtime now prefers bundled binaries before checking system PATH.
- `yt-dlp` is bundled as a portable standalone binary.
- `ffmpeg` and `ffprobe` are bundled along with their non-system dynamic libraries.
- `fpcalc` is bundled along with its non-system dynamic libraries.
- Result: shipped app and pkg are self-contained for these runtime dependencies.
