#!/bin/bash
# Bootstraps the runtime dependencies SeratoTools relies on:
#   - Homebrew (installed per-user, never as root)
#   - yt-dlp   (YouTube import/rip)
#   - ffmpeg   (audio transcode/probe; provides ffprobe)
#   - chromaprint (provides fpcalc for AcoustID audio fingerprinting)
#
# It is idempotent and safe to re-run. It is designed to work in two contexts:
#   1. Run directly by a logged-in user (e.g. from the app), possibly prompting
#      for an administrator password when Homebrew needs it.
#   2. Run as root from the installer .pkg postinstall, in which case it
#      re-targets the work to the current console (GUI) user, because Homebrew
#      refuses to run as root.
#
# The script is best-effort: the shipped app already bundles portable copies of
# these tools, so a failure here never blocks the app. All output is logged.
set -u

LOG_FILE="${SERATOTOOLS_DEPS_LOG:-/tmp/seratotools-install-dependencies.log}"

log() {
	printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" | tee -a "$LOG_FILE" >&2
}

# ---------------------------------------------------------------------------
# Re-target to the console user when invoked as root (installer postinstall).
# ---------------------------------------------------------------------------
if [[ "$(id -u)" -eq 0 ]]; then
	CONSOLE_USER="$(/usr/bin/stat -f%Su /dev/console 2>/dev/null || true)"
	if [[ -z "$CONSOLE_USER" || "$CONSOLE_USER" == "root" ]]; then
		log "No non-root console user is logged in; skipping dependency bootstrap."
		exit 0
	fi

	CONSOLE_UID="$(id -u "$CONSOLE_USER" 2>/dev/null || true)"
	if [[ -z "$CONSOLE_UID" ]]; then
		log "Could not resolve uid for console user '$CONSOLE_USER'; skipping."
		exit 0
	fi

	# Pre-stage the Homebrew prefix as root so the user-context install does not
	# need an interactive sudo password. Only relevant on a first-time install.
	ARCH="$(/usr/bin/uname -m)"
	if [[ "$ARCH" == "arm64" ]]; then
		BREW_PREFIX="/opt/homebrew"
		if [[ ! -x "$BREW_PREFIX/bin/brew" ]]; then
			log "Pre-staging $BREW_PREFIX for $CONSOLE_USER (arm64)."
			/bin/mkdir -p "$BREW_PREFIX"
			/usr/sbin/chown -R "$CONSOLE_USER:admin" "$BREW_PREFIX"
		fi
	else
		if [[ ! -x "/usr/local/bin/brew" ]]; then
			log "Pre-staging /usr/local for $CONSOLE_USER (x86_64)."
			for dir in bin etc include lib sbin share var opt Cellar Caskroom Frameworks Homebrew; do
				/bin/mkdir -p "/usr/local/$dir"
				/usr/sbin/chown -R "$CONSOLE_USER:admin" "/usr/local/$dir"
			done
		fi
	fi

	log "Re-running dependency bootstrap as console user '$CONSOLE_USER'."
	exec /bin/launchctl asuser "$CONSOLE_UID" /usr/bin/sudo -u "$CONSOLE_USER" \
		/bin/bash "$0" "$@"
fi

# ---------------------------------------------------------------------------
# From here on we are running as a normal (non-root) user.
# ---------------------------------------------------------------------------
export HOMEBREW_NO_AUTO_UPDATE=1
export HOMEBREW_NO_ENV_HINTS=1
export HOMEBREW_NO_ANALYTICS=1
export NONINTERACTIVE=1

resolve_brew() {
	if command -v brew >/dev/null 2>&1; then
		command -v brew
		return 0
	fi
	for candidate in /opt/homebrew/bin/brew /usr/local/bin/brew; do
		if [[ -x "$candidate" ]]; then
			echo "$candidate"
			return 0
		fi
	done
	return 1
}

install_homebrew() {
	local arch prefix repo
	arch="$(/usr/bin/uname -m)"

	# When the prefix was pre-staged (owned by us), install without sudo via the
	# portable tarball. Otherwise fall back to the official installer, which may
	# prompt for an administrator password.
	if [[ "$arch" == "arm64" ]]; then
		prefix="/opt/homebrew"
		repo="$prefix"
	else
		prefix="/usr/local"
		repo="$prefix/Homebrew"
	fi

	# The tarball path only works when we can write the repo location without
	# sudo (true after the installer pre-staged and chowned it for us).
	local repo_parent
	repo_parent="$(dirname "$repo")"
	if [[ ! -x "$prefix/bin/brew" && ( -w "$repo" || -w "$repo_parent" ) ]]; then
		log "Installing Homebrew into $repo via portable tarball (no sudo)."
		/bin/mkdir -p "$repo"
		if curl -fsSL https://github.com/Homebrew/brew/tarball/master \
			| tar xz --strip-components 1 -C "$repo"; then
			if [[ "$arch" != "arm64" ]]; then
				/bin/mkdir -p "$prefix/bin"
				ln -sf "$repo/bin/brew" "$prefix/bin/brew"
			fi
		else
			log "Portable Homebrew install failed; will try official installer."
		fi
	fi

	if ! resolve_brew >/dev/null 2>&1; then
		log "Installing Homebrew via official installer."
		if ! /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"; then
			log "Homebrew installation failed."
			return 1
		fi
	fi

	local brew_path
	brew_path="$(resolve_brew || true)"
	if [[ -n "$brew_path" ]]; then
		eval "$("$brew_path" shellenv)" || true
		# Finish setting up a freshly extracted tarball checkout.
		"$brew_path" update --force --quiet >>"$LOG_FILE" 2>&1 || true
	fi
}

ensure_formula() {
	local check_command="$1"
	local formula="$2"
	local brew_path="$3"

	if command -v "$check_command" >/dev/null 2>&1; then
		log "$check_command already available; skipping $formula."
		return 0
	fi

	if "$brew_path" list --formula "$formula" >/dev/null 2>&1; then
		log "$formula already installed via Homebrew."
		return 0
	fi

	log "Installing $formula via Homebrew..."
	if "$brew_path" install "$formula" >>"$LOG_FILE" 2>&1; then
		log "Installed $formula."
	else
		log "Failed to install $formula (see $LOG_FILE)."
		return 1
	fi
}

main() {
	log "Starting SeratoTools dependency bootstrap (user: $(id -un), arch: $(/usr/bin/uname -m))."

	local brew_path
	if ! brew_path="$(resolve_brew)"; then
		install_homebrew || true
		brew_path="$(resolve_brew || true)"
	fi

	if [[ -z "$brew_path" ]]; then
		log "Homebrew is unavailable; cannot install yt-dlp/ffmpeg/chromaprint."
		log "The app still works using its bundled runtime tools."
		exit 0
	fi

	eval "$("$brew_path" shellenv)" || true

	local overall=0
	ensure_formula yt-dlp yt-dlp "$brew_path" || overall=1
	ensure_formula ffmpeg ffmpeg "$brew_path" || overall=1
	ensure_formula fpcalc chromaprint "$brew_path" || overall=1

	if [[ "$overall" -eq 0 ]]; then
		log "Dependency bootstrap completed successfully."
	else
		log "Dependency bootstrap finished with some failures (see $LOG_FILE)."
	fi

	# Never fail the caller (e.g. the installer); the app bundles fallbacks.
	exit 0
}

main "$@"
