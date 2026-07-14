#!/bin/bash
# Builds SeratoTools.app and a standalone macOS installer package (.pkg).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_NAME="SeratoTools"
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

APP_PATH="/Applications/SeratoTools.app"
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
# console user and is fully best-effort: the app ships portable copies of these
# tools, so this only provides/updates system-wide installs and never blocks
# the installer. It runs detached so a first-time Homebrew install (which can
# take several minutes and hit the network) does not stall the installer UI.
BOOTSTRAP="$APP_PATH/Contents/Resources/scripts/install-dependencies.sh"
if [[ -x "$BOOTSTRAP" ]]; then
  log "Launching dependency bootstrap: $BOOTSTRAP"
  SERATOTOOLS_DEPS_LOG="/tmp/seratotools-install-dependencies.log" \
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

if [[ -n "${SERATOTOOLS_PKG_SIGN_IDENTITY:-}" ]]; then
  PKGBUILD_ARGS+=(--sign "$SERATOTOOLS_PKG_SIGN_IDENTITY")
fi

pkgbuild "${PKGBUILD_ARGS[@]}" "$PKG_PATH"

echo "Built installer: $PKG_PATH"
echo "Install with: installer -pkg \"$PKG_PATH\" -target /"
echo "On install, the pkg bootstraps Homebrew + yt-dlp + ffmpeg + chromaprint for the logged-in user (best effort; the app also bundles portable copies)."
echo "Quick Action setup after install: /Applications/SeratoTools.app/Contents/Resources/scripts/install-finder-quick-action.sh"
