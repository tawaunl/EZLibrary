#!/bin/bash
# Builds a release binary via SwiftPM and assembles it into a launchable
# EZLibrary.app bundle under dist/, without requiring full Xcode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="EZLibrary"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
RESOURCE_BIN_DIR="$APP_BUNDLE/Contents/Resources/bin"
RESOURCE_SCRIPT_DIR="$APP_BUNDLE/Contents/Resources/scripts"
BUILD_ARTIFACT_DIR="$DIST_DIR/build-artifacts"
BUILD_UNIVERSAL="${SERATOTOOLS_BUILD_UNIVERSAL:-0}"

build_product_binary() {
	# The app and CLI binaries are ALWAYS built as universal2 (arm64 + x86_64)
	# so the shipped app launches on both Apple Silicon and Intel Macs. An
	# arm64-only app triggers macOS "This application is not supported on this
	# Mac" on Intel. Cross-compiling the Swift binaries is cheap and does not
	# require Intel Homebrew runtime tools (those are handled separately).
	local product="$1"
	local output_path="$2"
	local arch
	local build_path
	local arch_bin_dir
	local arch_bin_path
	local arch_bins=()

	for arch in arm64 x86_64; do
		build_path="$BUILD_ARTIFACT_DIR/.swift-build-$product-$arch"
		rm -rf "$build_path"
		swift build -c release --product "$product" --arch "$arch" --build-path "$build_path"
		arch_bin_dir="$(swift build -c release --product "$product" --arch "$arch" --build-path "$build_path" --show-bin-path)"
		arch_bin_path="$arch_bin_dir/$product"
		if [[ ! -x "$arch_bin_path" ]]; then
			echo "Error: expected built binary not found at $arch_bin_path" >&2
			exit 1
		fi
		arch_bins+=("$arch_bin_path")
	done

	lipo -create "${arch_bins[@]}" -output "$output_path"
	chmod +x "$output_path"
	verify_universal_macho "$output_path" "$product app binary"
}

verify_universal_macho() {
	local file_path="$1"
	local label="$2"
	local info

	info="$(lipo -info "$file_path" 2>/dev/null || true)"
	if [[ -z "$info" ]]; then
		echo "Error: $label is not a Mach-O binary: $file_path" >&2
		exit 1
	fi

	if [[ "$info" != *"arm64"* || "$info" != *"x86_64"* ]]; then
		echo "Error: $label is not universal2 (missing arm64 or x86_64): $file_path" >&2
		echo "lipo info: $info" >&2
		echo "On Apple Silicon, install the Intel toolchain (Rosetta) and retry." >&2
		exit 1
	fi
}

cd "$ROOT_DIR"

echo "Building universal2 app and CLI binaries (arm64 + x86_64)..."
echo "Runtime tools (yt-dlp, ffmpeg/ffprobe, fpcalc) are NOT bundled; the app installs and keeps them current via Homebrew on the user's machine."

rm -rf "$BUILD_ARTIFACT_DIR"
mkdir -p "$BUILD_ARTIFACT_DIR"
APP_BIN_PATH="$BUILD_ARTIFACT_DIR/$APP_NAME"
CLI_BIN_PATH="$BUILD_ARTIFACT_DIR/SeratoToolsCLI"

build_product_binary "$APP_NAME" "$APP_BIN_PATH"
build_product_binary "SeratoToolsCLI" "$CLI_BIN_PATH"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$RESOURCE_BIN_DIR" "$RESOURCE_SCRIPT_DIR"

cp "$APP_BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"
cp "$CLI_BIN_PATH" "$RESOURCE_BIN_DIR/SeratoToolsCLI"
chmod +x "$RESOURCE_BIN_DIR/SeratoToolsCLI"

# App icon (referenced by CFBundleIconFile in Info.plist).
if [[ -f "$ROOT_DIR/Packaging/AppIcon.icns" ]]; then
	cp "$ROOT_DIR/Packaging/AppIcon.icns" "$APP_BUNDLE/Contents/Resources/AppIcon.icns"
else
	echo "Warning: Packaging/AppIcon.icns not found; app will build without a custom icon." >&2
fi

# Bundle scripts so Quick Actions can be installed from /Applications/EZLibrary.app.
cp "$ROOT_DIR/Scripts/finder-add-music.sh" "$RESOURCE_SCRIPT_DIR/finder-add-music.sh"
if [[ -f "$ROOT_DIR/Scripts/install-finder-quick-action-from-app.sh" ]]; then
	cp "$ROOT_DIR/Scripts/install-finder-quick-action-from-app.sh" "$RESOURCE_SCRIPT_DIR/install-finder-quick-action.sh"
fi
# Bundle the dependency bootstrap so the installer and the app can install
# Homebrew + yt-dlp + ffmpeg + chromaprint on a fresh machine.
cp "$ROOT_DIR/Scripts/install-dependencies.sh" "$RESOURCE_SCRIPT_DIR/install-dependencies.sh"
chmod +x "$RESOURCE_SCRIPT_DIR"/*.sh

# NOTE: The runtime command-line tools (yt-dlp, ffmpeg, ffprobe, fpcalc) are
# intentionally NOT bundled. The app installs them via Homebrew on first launch
# and keeps them current, so they never go stale. See RuntimeDependencyService.

if [[ "$BUILD_UNIVERSAL" == "1" ]]; then
	verify_universal_macho "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "app executable"
	verify_universal_macho "$RESOURCE_BIN_DIR/SeratoToolsCLI" "CLI executable"
fi

# Ad-hoc sign so Gatekeeper allows a local launch.
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
echo "Runtime tools (yt-dlp, ffmpeg/ffprobe, fpcalc) are installed and kept current via Homebrew on the user's machine — nothing is bundled."
echo "App + CLI binaries: universal2 (arm64 + x86_64) — runs on Apple Silicon and Intel."
