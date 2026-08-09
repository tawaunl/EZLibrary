#!/bin/bash
# Convenience: build the standalone installer and publish it as a GitHub Release.
#
# Usage:
#   ./Scripts/release.sh
#
# Environment overrides:
#   EZLIBRARY_BUILD_UNIVERSAL=1     Build a universal2 (arm64 + x86_64) pkg.
#                                   Requires universal Homebrew runtime deps.
#   RELEASE_TAG=v1.2.3              Override the git tag (default: v<pkg-version>).
#   RELEASE_DRAFT=1                 Create the release as a draft.
#   RELEASE_TARGET=main            Commitish the tag points at (default: current branch).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/Packaging/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$ROOT_DIR/Packaging/Info.plist")"
PKG_VERSION="$APP_VERSION"
if [[ -n "$APP_BUILD" ]]; then
  PKG_VERSION="$APP_VERSION.$APP_BUILD"
fi

TAG="${RELEASE_TAG:-v$PKG_VERSION}"
PKG_PATH="$ROOT_DIR/dist/EZLibrary-$PKG_VERSION.pkg"
PKG_NAME="EZLibrary-$PKG_VERSION.pkg"

# --- Preconditions --------------------------------------------------------
if ! command -v gh >/dev/null 2>&1; then
  echo "Error: GitHub CLI (gh) is required. Install with: brew install gh" >&2
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "Error: gh is not authenticated. Run: gh auth login" >&2
  exit 1
fi

if [[ -n "$(git status --porcelain)" ]]; then
  echo "Warning: working tree has uncommitted changes; the release tag will point"
  echo "         at committed history, not your local edits." >&2
fi

# --- Build ----------------------------------------------------------------
echo "Building installer for version $PKG_VERSION..."
"$ROOT_DIR/Scripts/build-installer.sh"

if [[ ! -f "$PKG_PATH" ]]; then
  echo "Error: expected installer not found at $PKG_PATH" >&2
  exit 1
fi

# --- Notarize -------------------------------------------------------------
# Signing lets the app launch; notarization is what stops Gatekeeper warning on
# a Mac that has never seen it before. A signed package that skipped this step
# still triggers the warning, so it is on by default rather than opt-in.
NOTARIZED=0
if pkgutil --check-signature "$PKG_PATH" >/dev/null 2>&1; then
  if [[ "${RELEASE_SKIP_NOTARIZE:-0}" == "1" ]]; then
    echo "Skipping notarization (RELEASE_SKIP_NOTARIZE=1). Users will see the Gatekeeper warning."
  else
    "$ROOT_DIR/Scripts/notarize.sh" "$PKG_PATH"
    NOTARIZED=1
  fi
else
  echo "Warning: the package is unsigned, so it cannot be notarized and macOS will" >&2
  echo "         warn on first open. Install Developer ID certificates to fix this." >&2
fi

# Checksummed after notarization on purpose: stapling the ticket rewrites the
# package, so a hash taken before it would not match what users download.
SHASUM="$(shasum -a 256 "$PKG_PATH" | awk '{print $1}')"

# --- Release notes --------------------------------------------------------
NOTES_FILE="$(mktemp)"
trap 'rm -f "$NOTES_FILE"' EXIT

# Pull the highlights for this version from docs/CHANGELOG.md (the block between
# "## <version>" and the next "## " heading), if present.
CHANGELOG_FILE="$ROOT_DIR/docs/CHANGELOG.md"
HIGHLIGHTS=""
if [[ -f "$CHANGELOG_FILE" ]]; then
  HIGHLIGHTS="$(awk -v ver="$PKG_VERSION" '
    index($0, "## " ver) == 1 { capture = 1; next }
    /^## / { capture = 0 }
    capture { blanks = blanks $0 "\n"; if ($0 ~ /[^[:space:]]/) { printf "%s", blanks; blanks = "" } }
  ' "$CHANGELOG_FILE" | sed -e '/./,$!d')"
fi

if [[ -n "$HIGHLIGHTS" ]]; then
  cat > "$NOTES_FILE" <<EOF
## What's New in $PKG_VERSION

$HIGHLIGHTS

EOF
fi

if [[ "$NOTARIZED" == "1" ]]; then
  cat >> "$NOTES_FILE" <<EOF
## Install

1. Download **$PKG_NAME** from the Assets below.
2. Open it and follow the installer.

This build is signed with an Apple Developer ID and notarized by Apple, so it
installs without any security warning.

EOF
else
  cat >> "$NOTES_FILE" <<EOF
## Install

This build is **not notarized**, so macOS Gatekeeper will warn on first open.
To install:

1. Download **$PKG_NAME** from the Assets below.
2. **Right-click** the downloaded file → **Open** → **Open** in the dialog.
   - Or via Terminal: \`sudo installer -pkg "$PKG_NAME" -target /\`
   - Or allow it under **System Settings → Privacy & Security → Open Anyway**.

EOF
fi

cat >> "$NOTES_FILE" <<EOF
## What it installs

- \`EZLibrary.app\` into /Applications
- On install (and on every launch), EZLibrary installs and keeps its
  command-line tools — \`yt-dlp\`, \`ffmpeg\`/\`ffprobe\`, and \`fpcalc\` —
  up to date via Homebrew. Nothing is bundled, so the tools always stay current.

## Checksum (SHA-256)

\`\`\`
$SHASUM  $PKG_NAME
\`\`\`
EOF

# --- Publish --------------------------------------------------------------
CREATE_ARGS=(
  "$TAG"
  "$PKG_PATH"
  --title "EZLibrary $PKG_VERSION"
  --notes-file "$NOTES_FILE"
)

if [[ -n "${RELEASE_TARGET:-}" ]]; then
  CREATE_ARGS+=(--target "$RELEASE_TARGET")
fi

if [[ "${RELEASE_DRAFT:-0}" == "1" ]]; then
  CREATE_ARGS+=(--draft)
fi

if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists; uploading asset (clobbering existing)..."
  gh release upload "$TAG" "$PKG_PATH" --clobber
else
  echo "Creating release $TAG..."
  gh release create "${CREATE_ARGS[@]}"
fi

echo ""
echo "Published: $TAG"
echo "Asset:     $PKG_NAME"
echo "SHA-256:   $SHASUM"
