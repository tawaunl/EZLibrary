#!/bin/bash
# Builds a release binary via SwiftPM and assembles it into a launchable
# SeratoTools.app bundle under dist/, without requiring full Xcode.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_NAME="SeratoTools"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"

cd "$ROOT_DIR"
swift build -c release --product "$APP_NAME"

BIN_PATH="$(swift build -c release --product "$APP_NAME" --show-bin-path)/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_BUNDLE/Contents/MacOS" "$APP_BUNDLE/Contents/Resources"

cp "$BIN_PATH" "$APP_BUNDLE/Contents/MacOS/$APP_NAME"
cp "$ROOT_DIR/Packaging/Info.plist" "$APP_BUNDLE/Contents/Info.plist"

# Ad-hoc sign so Gatekeeper allows a local launch.
codesign --force --deep --sign - "$APP_BUNDLE"

echo "Built $APP_BUNDLE"
