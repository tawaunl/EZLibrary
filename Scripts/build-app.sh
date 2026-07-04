#!/bin/bash
# Builds a release binary via SwiftPM and assembles it into a launchable
# SeratoTools.app bundle under dist/, without requiring full Xcode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SeratoTools"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
RESOURCE_BIN_DIR="$APP_BUNDLE/Contents/Resources/bin"
RESOURCE_SCRIPT_DIR="$APP_BUNDLE/Contents/Resources/scripts"

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

bundle_tool() {
	local source_path="$1"
	local target_name="$2"
	local required_label="$3"

	if [[ -z "$source_path" || ! -x "$source_path" ]]; then
		if [[ -n "$required_label" ]]; then
			echo "Error: required dependency '$required_label' is missing and could not be bundled." >&2
			exit 1
		fi
		return
	fi

	cp -f "$source_path" "$RESOURCE_BIN_DIR/$target_name"
	chmod +x "$RESOURCE_BIN_DIR/$target_name"
}

resolve_path_from_command() {
	local command_name="$1"
	command -v "$command_name" 2>/dev/null || true
}

cd "$ROOT_DIR"
ensure_fpcalc
swift build -c release --product "$APP_NAME"
swift build -c release --product SeratoToolsCLI

BIN_DIR="$(swift build -c release --product "$APP_NAME" --show-bin-path)"
APP_BIN_PATH="$BIN_DIR/$APP_NAME"
CLI_BIN_PATH="$BIN_DIR/SeratoToolsCLI"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$RESOURCE_BIN_DIR" "$RESOURCE_SCRIPT_DIR"

cp "$APP_BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$CLI_BIN_PATH" "$RESOURCE_BIN_DIR/SeratoToolsCLI"
chmod +x "$RESOURCE_BIN_DIR/SeratoToolsCLI"

# Bundle scripts so Quick Actions can be installed from /Applications/SeratoTools.app.
cp "$ROOT_DIR/Scripts/finder-add-music.sh" "$RESOURCE_SCRIPT_DIR/finder-add-music.sh"
if [[ -f "$ROOT_DIR/Scripts/install-finder-quick-action-from-app.sh" ]]; then
	cp "$ROOT_DIR/Scripts/install-finder-quick-action-from-app.sh" "$RESOURCE_SCRIPT_DIR/install-finder-quick-action.sh"
fi
chmod +x "$RESOURCE_SCRIPT_DIR"/*.sh

# Required for audio fingerprint lookup.
FPCALC_PATH="$(resolve_path_from_command fpcalc)"
bundle_tool "$FPCALC_PATH" "fpcalc" "fpcalc"

# Optional, but bundling them makes YouTube import work out of the box when
# already available on the build machine.
YTDLP_PATH="$(resolve_path_from_command yt-dlp)"
FFMPEG_PATH="$(resolve_path_from_command ffmpeg)"
bundle_tool "$YTDLP_PATH" "yt-dlp" ""
bundle_tool "$FFMPEG_PATH" "ffmpeg" ""

# Ad-hoc sign so Gatekeeper allows a local launch.
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
if [[ -x "$RESOURCE_BIN_DIR/yt-dlp" && -x "$RESOURCE_BIN_DIR/ffmpeg" ]]; then
	echo "Bundled: fpcalc, yt-dlp, ffmpeg"
else
	echo "Bundled: fpcalc"
	echo "Optional tools not fully bundled (yt-dlp and/or ffmpeg missing on build host)."
fi
