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
set -euo pipefail

APP_PATH="/Applications/SeratoTools.app"

# Best effort cleanup for local installs copied via package tools.
if [[ -d "$APP_PATH" ]]; then
  xattr -dr com.apple.quarantine "$APP_PATH" >/dev/null 2>&1 || true
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
echo "Quick Action setup after install: /Applications/SeratoTools.app/Contents/Resources/scripts/install-finder-quick-action.sh"
