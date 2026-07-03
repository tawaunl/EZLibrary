#!/bin/bash
# Builds a release binary via SwiftPM and assembles it into a launchable
# SeratoTools.app bundle under dist/, without requiring full Xcode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SeratoTools"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

ensure_homebrew() {
	if command -v brew >/dev/null 2>&1; then
		return
	fi

	echo "Homebrew not found. Attempting automatic install..."

	if ! command -v curl >/dev/null 2>&1; then
		echo "Error: curl is required to install Homebrew automatically." >&2
		exit 1
	fi

	NONINTERACTIVE=1 /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

	# Ensure common Homebrew locations are on PATH for this script run.
	if [[ -x /opt/homebrew/bin/brew ]]; then
		eval "$(/opt/homebrew/bin/brew shellenv)"
	elif [[ -x /usr/local/bin/brew ]]; then
		eval "$(/usr/local/bin/brew shellenv)"
	fi

	if ! command -v brew >/dev/null 2>&1; then
		echo "Error: Homebrew installation did not complete. Please install manually from https://brew.sh and re-run." >&2
		exit 1
	fi
}

ensure_fpcalc() {
	if command -v fpcalc >/dev/null 2>&1; then
		return
	fi

	echo "fpcalc not found. Installing chromaprint via Homebrew..."
	ensure_homebrew

	brew install chromaprint

	if ! command -v fpcalc >/dev/null 2>&1; then
		echo "Error: fpcalc installation appears to have failed." >&2
		exit 1
	fi
}

cd "$ROOT_DIR"
ensure_fpcalc
swift build -c release --product "$APP_NAME"

BIN_PATH="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Ad-hoc sign so Gatekeeper allows a local launch.
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
