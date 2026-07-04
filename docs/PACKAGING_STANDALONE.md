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

Output:

- `dist/SeratoTools.app`

## Build installer package (.pkg)

From repository root:

```bash
./Scripts/build-installer.sh
```

Output:

- `dist/SeratoTools-<version>.pkg`

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
- `yt-dlp` and `ffmpeg` are optional at build time; if not bundled, users can still install them later with Homebrew.
- Runtime now prefers bundled binaries before checking system PATH.
