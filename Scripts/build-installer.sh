#!/bin/bash
# Builds EZLibrary.app and a standalone macOS installer package (.pkg).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="EZLibrary"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

APP_VERSION="$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$ROOT_DIR/Packaging/Info.plist")"
APP_BUILD="$(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$ROOT_DIR/Packaging/Info.plist")"
PKG_VERSION="$APP_VERSION"
if [[ -n "$APP_BUILD" ]]; then
  PKG_VERSION="$APP_VERSION.$APP_BUILD"
fi

PKG_ID="com.seratotools.app"
PKG_PATH="$DIST_DIR/$APP_NAME-$PKG_VERSION.pkg"
PKGROOT="$DIST_DIR/pkgroot-$$"
PKGSCRIPTS="$DIST_DIR/pkgscripts-$$"

cleanup() {
  rm -rf "$PKGROOT" "$PKGSCRIPTS" >/dev/null 2>&1 || true
}
trap cleanup EXIT

"$ROOT_DIR/Scripts/build-app.sh"

mkdir -p "$PKGROOT/Applications" "$PKGSCRIPTS"
cp -R "$APP_BUNDLE" "$PKGROOT/Applications/$APP_NAME.app"

cat > "$PKGSCRIPTS/postinstall" <<'EOF'
#!/bin/bash
# Runs as root after the app is copied into /Applications.
set -u

APP_PATH="/Applications/EZLibrary.app"
LOG_FILE="/tmp/seratotools-postinstall.log"

log() {
  printf '%s %s\n' "$(date '+%Y-%m-%dT%H:%M:%S')" "$*" >>"$LOG_FILE" 2>&1 || true
}

# Best effort cleanup for local installs copied via package tools.
if [[ -d "$APP_PATH" ]]; then
  xattr -dr com.apple.quarantine "$APP_PATH" >/dev/null 2>&1 || true
fi

# Bootstrap runtime dependencies (Homebrew + yt-dlp + ffmpeg + chromaprint) for
# the logged-in user. The bundled script re-targets itself from root to the
# console user and is best-effort. The app no longer bundles these tools, so
# this pre-installs them at install time; the app also re-checks and installs
# them on every launch. It runs detached so a first-time Homebrew install
# (which can take several minutes and hit the network) does not stall the
# installer UI.
BOOTSTRAP="$APP_PATH/Contents/Resources/scripts/install-dependencies.sh"
if [[ -x "$BOOTSTRAP" ]]; then
  log "Launching dependency bootstrap: $BOOTSTRAP"
  SERATOTOOLS_DEPS_LOG="/tmp/seratotools-install-dependencies.log" \
    EZLIBRARY_DEPS_LOG="/tmp/seratotools-install-dependencies.log" \
    nohup /bin/bash "$BOOTSTRAP" >>"$LOG_FILE" 2>&1 </dev/null &
  disown 2>/dev/null || true
else
  log "Dependency bootstrap script not found at $BOOTSTRAP"
fi

exit 0
EOF

chmod +x "$PKGSCRIPTS/postinstall"

PKGBUILD_ARGS=(
  --root "$PKGROOT"
  --identifier "$PKG_ID"
  --version "$PKG_VERSION"
  --install-location "/"
  --scripts "$PKGSCRIPTS"
)

# A .pkg is signed with a "Developer ID Installer" certificate — a different
# certificate from the "Developer ID Application" one that signs the app inside
# it. Both are needed: the app signature is what lets it launch, the installer
# signature is what lets the .pkg open without a warning of its own.
#
# Resolved like the app identity: explicit env var, else the newest matching
# identity in the keychain, else leave the package unsigned.
# Prints the SHA-1 of the valid identity whose name starts with $1 and whose
# certificate expires last; extra args go to `security find-identity`.
#
# Selecting by hash rather than name matters when certificates are renewed:
# the old and new ones share the exact same name until the old one expires,
# and codesign/pkgbuild refuse a name that matches more than one identity.
#
# Nothing in here may fail the build: under `set -euo pipefail` a missing
# certificate would otherwise abort instead of falling through to the
# unsigned path, hence the `|| true`s.
newest_identity() {
  local prefix="$1"
  shift
  security find-identity -v "$@" 2>/dev/null \
    | sed -n "s/^ *[0-9]*) \([0-9A-F]\{40\}\) \"\(${prefix}[^\"]*\)\"$/\1 \2/p" \
    | while read -r hash name; do
      local end
      end="$(security find-certificate -a -Z -p -c "$name" 2>/dev/null \
        | awk -v h="$hash" '/^SHA-1 hash:/ {keep = ($3 == h); next} keep' \
        | /usr/bin/openssl x509 -noout -enddate 2>/dev/null \
        | cut -d= -f2)" || true
      [[ -n "$end" ]] || continue
      echo "$(date -j -u -f '%b %e %T %Y %Z' "$end" +%s 2>/dev/null || echo 0) $hash"
    done \
    | sort -rn | head -1 | cut -d' ' -f2 || true
}

resolve_pkg_sign_identity() {
  local explicit="${EZLIBRARY_PKG_SIGN_IDENTITY:-${SERATOTOOLS_PKG_SIGN_IDENTITY:-}}"
  if [[ -n "$explicit" ]]; then
    echo "$explicit"
    return
  fi
  newest_identity "Developer ID Installer:"
}

PKG_SIGN_IDENTITY="$(resolve_pkg_sign_identity)"

if [[ -n "$PKG_SIGN_IDENTITY" ]]; then
  echo "Signing installer with: $PKG_SIGN_IDENTITY"
  PKGBUILD_ARGS+=(--sign "$PKG_SIGN_IDENTITY" --timestamp)
else
  echo "No Developer ID Installer identity found; building an unsigned package."
fi

pkgbuild "${PKGBUILD_ARGS[@]}" "$PKG_PATH"

if [[ -n "$PKG_SIGN_IDENTITY" ]]; then
  # Confirms the package carries a valid signature chain before it is uploaded
  # or handed to notarization.
  pkgutil --check-signature "$PKG_PATH" >/dev/null
  echo "Installer signature verified."
fi

echo "Built installer: $PKG_PATH"
echo "Install with: installer -pkg \"$PKG_PATH\" -target /"
echo "On install, the pkg bootstraps Homebrew + yt-dlp + ffmpeg + chromaprint for the logged-in user (best effort; the app also re-checks and installs them on every launch)."
echo "Quick Action setup after install: /Applications/EZLibrary.app/Contents/Resources/scripts/install-finder-quick-action.sh"
