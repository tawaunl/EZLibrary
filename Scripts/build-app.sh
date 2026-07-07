#!/bin/bash
# Builds a release binary via SwiftPM and assembles it into a launchable
# SeratoTools.app bundle under dist/, without requiring full Xcode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SeratoTools"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
RESOURCE_BIN_DIR="$APP_BUNDLE/Contents/Resources/bin"
RESOURCE_LIB_DIR="$APP_BUNDLE/Contents/Resources/lib"
RESOURCE_SCRIPT_DIR="$APP_BUNDLE/Contents/Resources/scripts"
BUILD_ARTIFACT_DIR="$DIST_DIR/build-artifacts"
BUILD_UNIVERSAL="${SERATOTOOLS_BUILD_UNIVERSAL:-0}"

_copied_libs_set=""
_processed_files_set=""
_work_queue=()
_runtime_roots=()

set_contains() {
	local set_content="$1"
	local needle="$2"
	[[ $'\n'"$set_content"$'\n' == *$'\n'"$needle"$'\n'* ]]
}

set_add() {
	local set_name="$1"
	local value="$2"
	local current
	current="${!set_name}"
	if ! set_contains "$current" "$value"; then
		if [[ -n "$current" ]]; then
			current="$current"$'\n'"$value"
		else
			current="$value"
		fi
		printf -v "$set_name" '%s' "$current"
	fi
}

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

ensure_brew_package() {
	local command_name="$1"
	local brew_formula="$2"

	if command -v "$command_name" >/dev/null 2>&1; then
		return
	fi

	echo "$command_name not found. Installing $brew_formula via Homebrew..."
	ensure_homebrew
	brew install "$brew_formula"

	if ! command -v "$command_name" >/dev/null 2>&1; then
		echo "Error: required dependency '$command_name' is missing after brew install $brew_formula." >&2
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

build_product_binary() {
	local product="$1"
	local output_path="$2"

	if [[ "$BUILD_UNIVERSAL" == "1" ]]; then
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
	else
		swift build -c release --product "$product"
		local bin_dir
		bin_dir="$(swift build -c release --product "$product" --show-bin-path)"
		cp "$bin_dir/$product" "$output_path"
		chmod +x "$output_path"
	fi
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
		echo "Hint: universal builds require universal runtime dependencies (fpcalc/ffmpeg/ffprobe and bundled dylibs)." >&2
		echo "On Apple Silicon, install Intel toolchain/deps (Rosetta + /usr/local Homebrew) and provide universal binaries, then retry." >&2
		exit 1
	fi
}

preflight_universal_dependency() {
	local command_name="$1"
	local resolved_path

	resolved_path="$(resolve_path_from_command "$command_name")"
	if [[ -z "$resolved_path" || ! -x "$resolved_path" ]]; then
		echo "Error: required dependency '$command_name' was not found for universal preflight." >&2
		exit 1
	fi

	verify_universal_macho "$resolved_path" "$command_name"
}

run_universal_preflight() {
	echo "Running universal preflight checks for runtime tools..."
	preflight_universal_dependency "fpcalc"
	preflight_universal_dependency "ffmpeg"
	preflight_universal_dependency "ffprobe"
	echo "Universal preflight passed for local runtime tools."
}

download_portable_ytdlp() {
	local out_path="$RESOURCE_BIN_DIR/yt-dlp"
	local url="https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp_macos"

	echo "Downloading portable yt-dlp binary..."
	if ! curl -fL "$url" -o "$out_path"; then
		echo "Error: failed to download portable yt-dlp binary from $url" >&2
		exit 1
	fi

	chmod +x "$out_path"
}

is_system_library() {
	local dep="$1"
	[[ "$dep" == /usr/lib/* || "$dep" == /System/* ]]
}

find_dependency_path() {
	local dep="$1"
	local requester="$2"
	local candidate

	if [[ "$dep" == /opt/* || "$dep" == /usr/local/* ]]; then
		if [[ -e "$dep" ]]; then
			echo "$dep"
			return 0
		fi
	fi

	if [[ "$dep" == @loader_path/* ]]; then
		candidate="$(dirname "$requester")/${dep#@loader_path/}"
		if [[ -e "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	fi

	if [[ "$dep" == @executable_path/* ]]; then
		candidate="$RESOURCE_BIN_DIR/${dep#@executable_path/}"
		if [[ -e "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	fi

	if [[ "$dep" == @rpath/* ]]; then
		local base
		local rpath
		base="$(basename "$dep")"

		while IFS= read -r rpath; do
			candidate="$rpath/$base"
			if [[ -e "$candidate" ]]; then
				echo "$candidate"
				return 0
			fi
		done < <(otool -l "$requester" | awk '/LC_RPATH/{getline; getline; if ($1=="path") print $2}')

		while IFS= read -r candidate; do
			echo "$candidate"
			return 0
		done < <(find /opt/homebrew /usr/local -name "$base" 2>/dev/null)
	fi

	return 1
}

queue_runtime_root() {
	local path="$1"
	_runtime_roots+=("$path")
	_work_queue+=("$path")
}

copy_and_queue_dependency() {
	local source_path="$1"
	local base
	local target

	base="$(basename "$source_path")"
	target="$RESOURCE_LIB_DIR/$base"

	if set_contains "$_copied_libs_set" "$base"; then
		return 0
	fi

	cp -fL "$source_path" "$target"
	chmod +w "$target" 2>/dev/null || true
	set_add _copied_libs_set "$base"
	_work_queue+=("$target")
}

collect_runtime_dependencies() {
	while [[ ${#_work_queue[@]} -gt 0 ]]; do
		local current
		current="${_work_queue[0]}"
		_work_queue=("${_work_queue[@]:1}")

		if set_contains "$_processed_files_set" "$current"; then
			continue
		fi
		set_add _processed_files_set "$current"

		if ! otool -L "$current" >/dev/null 2>&1; then
			continue
		fi

		while IFS= read -r dep; do
			[[ -z "$dep" ]] && continue
			if is_system_library "$dep"; then
				continue
			fi

			local dep_source
			if dep_source="$(find_dependency_path "$dep" "$current")"; then
				copy_and_queue_dependency "$dep_source"
			else
				echo "Error: could not resolve dependency '$dep' required by '$current'." >&2
				exit 1
			fi
		done < <(otool -L "$current" | awk 'NR>1 {print $1}')
	done
}

rewrite_links_for_file() {
	local file_path="$1"
	local dep
	local base
	local new_path

	if ! otool -L "$file_path" >/dev/null 2>&1; then
		return
	fi

	while IFS= read -r dep; do
		[[ -z "$dep" ]] && continue
		if is_system_library "$dep"; then
			continue
		fi

		base="$(basename "$dep")"
		if [[ ! -f "$RESOURCE_LIB_DIR/$base" ]]; then
			continue
		fi

		if [[ "$file_path" == "$RESOURCE_LIB_DIR"/* ]]; then
			new_path="@loader_path/$base"
		else
			new_path="@executable_path/../lib/$base"
		fi

		if [[ "$dep" != "$new_path" ]]; then
			install_name_tool -change "$dep" "$new_path" "$file_path"
		fi
	done < <(otool -L "$file_path" | awk 'NR>1 {print $1}')

	if [[ "$file_path" == "$RESOURCE_LIB_DIR"/* ]]; then
		install_name_tool -id "@loader_path/$(basename "$file_path")" "$file_path"
	fi
}

make_binaries_portable() {
	collect_runtime_dependencies

	local file_path
	for file_path in "${_runtime_roots[@]}"; do
		rewrite_links_for_file "$file_path"
	done

	for file_path in "$RESOURCE_LIB_DIR"/*.dylib; do
		[[ -e "$file_path" ]] || continue
		rewrite_links_for_file "$file_path"
	done
}

cd "$ROOT_DIR"
ensure_brew_package fpcalc chromaprint
ensure_brew_package ffmpeg ffmpeg

if [[ "$BUILD_UNIVERSAL" == "1" ]]; then
	run_universal_preflight
fi

if [[ "$BUILD_UNIVERSAL" == "1" ]]; then
	echo "Building universal2 app and CLI binaries (arm64 + x86_64)..."
else
	echo "Building native-architecture app and CLI binaries..."
fi

rm -rf "$BUILD_ARTIFACT_DIR"
mkdir -p "$BUILD_ARTIFACT_DIR"
APP_BIN_PATH="$BUILD_ARTIFACT_DIR/$APP_NAME"
CLI_BIN_PATH="$BUILD_ARTIFACT_DIR/SeratoToolsCLI"

build_product_binary "$APP_NAME" "$APP_BIN_PATH"
build_product_binary "SeratoToolsCLI" "$CLI_BIN_PATH"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources" "$RESOURCE_BIN_DIR" "$RESOURCE_LIB_DIR" "$RESOURCE_SCRIPT_DIR"

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

# Required for YouTube workflows.
FFMPEG_PATH="$(resolve_path_from_command ffmpeg)"
FFPROBE_PATH="$(resolve_path_from_command ffprobe)"
bundle_tool "$FFMPEG_PATH" "ffmpeg" "ffmpeg"
bundle_tool "$FFPROBE_PATH" "ffprobe" "ffprobe"

# Bundle a fully portable yt-dlp binary (not the Homebrew Python script shim).
download_portable_ytdlp

# Make ffmpeg/fpcalc self-contained by bundling their non-system shared libs.
queue_runtime_root "$RESOURCE_BIN_DIR/fpcalc"
queue_runtime_root "$RESOURCE_BIN_DIR/ffmpeg"
queue_runtime_root "$RESOURCE_BIN_DIR/ffprobe"
make_binaries_portable

if [[ "$BUILD_UNIVERSAL" == "1" ]]; then
	verify_universal_macho "$APP_BUNDLE/Contents/MacOS/$APP_NAME" "app executable"
	verify_universal_macho "$RESOURCE_BIN_DIR/SeratoToolsCLI" "CLI executable"
	verify_universal_macho "$RESOURCE_BIN_DIR/fpcalc" "fpcalc"
	verify_universal_macho "$RESOURCE_BIN_DIR/ffmpeg" "ffmpeg"
	verify_universal_macho "$RESOURCE_BIN_DIR/ffprobe" "ffprobe"
	verify_universal_macho "$RESOURCE_BIN_DIR/yt-dlp" "yt-dlp"

	for dylib_path in "$RESOURCE_LIB_DIR"/*.dylib; do
		[[ -e "$dylib_path" ]] || continue
		verify_universal_macho "$dylib_path" "bundled dylib"
	done
fi

# Ad-hoc sign so Gatekeeper allows a local launch.
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
echo "Bundled portable runtime tools: fpcalc, yt-dlp, ffmpeg, ffprobe"
if [[ "$BUILD_UNIVERSAL" == "1" ]]; then
	echo "Universal mode: enabled (validated universal2 artifacts)"
else
	echo "Universal mode: disabled (set SERATOTOOLS_BUILD_UNIVERSAL=1 to build universal2)"
fi
