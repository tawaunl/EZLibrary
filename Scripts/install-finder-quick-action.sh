#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SERVICE_NAME="Add To Serato Library"
SERVICE_DIR="$HOME/Library/Services/$SERVICE_NAME.workflow"
CONTENTS_DIR="$SERVICE_DIR/Contents"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

MODE="${SERATOTOOLS_ADD_MODE:-move}"
DESTINATION="${SERATOTOOLS_ADD_DESTINATION:-$HOME/Music}"
CRATE_PREFIX="${SERATOTOOLS_ADD_CRATE_PREFIX:-New Music}"
LIBRARY_DIR="${SERATOTOOLS_LIBRARY_DIR:-}"

if [[ "$MODE" != "move" && "$MODE" != "copy" ]]; then
  echo "Invalid SERATOTOOLS_ADD_MODE: $MODE (expected move or copy)" >&2
  exit 2
fi

xml_escape() {
  printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

SCRIPT_PATH="$ROOT_DIR/Scripts/finder-add-music.sh"
if [[ ! -x "$SCRIPT_PATH" ]]; then
  chmod +x "$SCRIPT_PATH"
fi

echo "Building SeratoToolsCLI so the Quick Action can run immediately..."
cd "$ROOT_DIR"
swift build --product SeratoToolsCLI >/dev/null

mkdir -p "$RESOURCES_DIR"

ACTION_UUID="$(uuidgen)"
INPUT_UUID="$(uuidgen)"
OUTPUT_UUID="$(uuidgen)"

COMMAND_STRING=$(cat <<EOF
export SERATOTOOLS_ADD_MODE="${MODE}"
export SERATOTOOLS_ADD_DESTINATION="${DESTINATION}"
export SERATOTOOLS_ADD_CRATE_PREFIX="${CRATE_PREFIX}"
export SERATOTOOLS_LIBRARY_DIR="${LIBRARY_DIR}"

"${SCRIPT_PATH}" "\$@"
EOF
)

COMMAND_STRING_ESCAPED="$(xml_escape "$COMMAND_STRING")"

cat > "$RESOURCES_DIR/document.wflow" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>AMApplicationBuild</key>
  <string>346</string>
  <key>AMApplicationVersion</key>
  <string>2.3</string>
  <key>AMDocumentVersion</key>
  <string>2</string>
  <key>actions</key>
  <array>
    <dict>
      <key>action</key>
      <dict>
        <key>ActionBundlePath</key>
        <string>/System/Library/Automator/Run Shell Script.action</string>
        <key>ActionName</key>
        <string>Run Shell Script</string>
        <key>ActionParameters</key>
        <dict>
          <key>COMMAND_STRING</key>
          <string>${COMMAND_STRING_ESCAPED}</string>
          <key>CheckedForUserDefaultShell</key>
          <true/>
          <key>inputMethod</key>
          <integer>1</integer>
          <key>shell</key>
          <string>/bin/bash</string>
          <key>source</key>
          <string></string>
        </dict>
        <key>AMAccepts</key>
        <dict>
          <key>Container</key>
          <string>List</string>
          <key>Optional</key>
          <true/>
          <key>Types</key>
          <array>
            <string>com.apple.cocoa.path</string>
          </array>
        </dict>
        <key>AMActionVersion</key>
        <string>2.0.3</string>
        <key>AMApplication</key>
        <array>
          <string>Automator</string>
        </array>
        <key>AMParameterProperties</key>
        <dict>
          <key>COMMAND_STRING</key>
          <dict/>
          <key>CheckedForUserDefaultShell</key>
          <dict/>
          <key>inputMethod</key>
          <dict/>
          <key>shell</key>
          <dict/>
          <key>source</key>
          <dict/>
        </dict>
        <key>AMProvides</key>
        <dict>
          <key>Container</key>
          <string>List</string>
          <key>Types</key>
          <array>
            <string>com.apple.cocoa.path</string>
          </array>
        </dict>
        <key>BundleIdentifier</key>
        <string>com.apple.RunShellScript</string>
        <key>CFBundleVersion</key>
        <string>2.0.3</string>
        <key>CanShowSelectedItemsWhenRun</key>
        <false/>
        <key>CanShowWhenRun</key>
        <true/>
        <key>Category</key>
        <array>
          <string>AMCategoryUtilities</string>
        </array>
        <key>Class Name</key>
        <string>RunShellScriptAction</string>
        <key>InputUUID</key>
        <string>${INPUT_UUID}</string>
        <key>OutputUUID</key>
        <string>${OUTPUT_UUID}</string>
        <key>UUID</key>
        <string>${ACTION_UUID}</string>
        <key>UnlocalizedApplications</key>
        <array>
          <string>Automator</string>
        </array>
        <key>arguments</key>
        <dict>
          <key>0</key>
          <dict>
            <key>default value</key>
            <integer>0</integer>
            <key>name</key>
            <string>inputMethod</string>
            <key>required</key>
            <string>0</string>
            <key>type</key>
            <string>0</string>
            <key>uuid</key>
            <string>0</string>
          </dict>
          <key>1</key>
          <dict>
            <key>default value</key>
            <string></string>
            <key>name</key>
            <string>source</string>
            <key>required</key>
            <string>0</string>
            <key>type</key>
            <string>0</string>
            <key>uuid</key>
            <string>1</string>
          </dict>
          <key>2</key>
          <dict>
            <key>default value</key>
            <false/>
            <key>name</key>
            <string>CheckedForUserDefaultShell</string>
            <key>required</key>
            <string>0</string>
            <key>type</key>
            <string>0</string>
            <key>uuid</key>
            <string>2</string>
          </dict>
          <key>3</key>
          <dict>
            <key>default value</key>
            <string></string>
            <key>name</key>
            <string>COMMAND_STRING</string>
            <key>required</key>
            <string>0</string>
            <key>type</key>
            <string>0</string>
            <key>uuid</key>
            <string>3</string>
          </dict>
          <key>4</key>
          <dict>
            <key>default value</key>
            <string>/bin/sh</string>
            <key>name</key>
            <string>shell</string>
            <key>required</key>
            <string>0</string>
            <key>type</key>
            <string>0</string>
            <key>uuid</key>
            <string>4</string>
          </dict>
        </dict>
      </dict>
      <key>isViewVisible</key>
      <true/>
    </dict>
  </array>
  <key>connectors</key>
  <dict/>
  <key>workflowMetaData</key>
  <dict>
    <key>serviceApplicationBundleID</key>
    <string>com.apple.finder</string>
    <key>serviceInputTypeIdentifier</key>
    <string>com.apple.Automator.fileSystemObject.music</string>
    <key>serviceOutputTypeIdentifier</key>
    <string>com.apple.Automator.nothing</string>
    <key>serviceProcessesInput</key>
    <integer>0</integer>
    <key>workflowTypeIdentifier</key>
    <string>com.apple.Automator.servicesMenu</string>
  </dict>
</dict>
</plist>
EOF

cat > "$CONTENTS_DIR/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key>
  <string>en_US</string>
  <key>CFBundleIdentifier</key>
  <string>com.tawaunlucas.seratotools.quickaction.addmusic</string>
  <key>CFBundleName</key>
  <string>Add To Serato Library</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>NSServices</key>
  <array>
    <dict>
      <key>NSMenuItem</key>
      <dict>
        <key>default</key>
        <string>Add To Serato Library</string>
      </dict>
      <key>NSMessage</key>
      <string>runWorkflowAsService</string>
      <key>NSRequiredContext</key>
      <dict>
        <key>NSApplicationIdentifier</key>
        <string>com.apple.finder</string>
      </dict>
      <key>NSSendFileTypes</key>
      <array>
        <string>public.audio</string>
        <string>public.folder</string>
      </array>
    </dict>
  </array>
</dict>
</plist>
EOF

cat > "$CONTENTS_DIR/version.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>BuildVersion</key>
  <string>1754</string>
  <key>CFBundleShortVersionString</key>
  <string>1.0</string>
  <key>ProjectName</key>
  <string>Automator</string>
  <key>SourceVersion</key>
  <string>534000000000000</string>
</dict>
</plist>
EOF

plutil -lint "$RESOURCES_DIR/document.wflow" >/dev/null
plutil -lint "$CONTENTS_DIR/Info.plist" >/dev/null
plutil -lint "$CONTENTS_DIR/version.plist" >/dev/null

# Refresh the Services daemon so Finder sees the new Quick Action.
if pgrep -x pbs >/dev/null 2>&1; then
  killall pbs || true
fi

echo "Installed Quick Action: $SERVICE_NAME"
echo "Path: $SERVICE_DIR"
echo "Mode: $MODE"
echo "Destination: $DESTINATION"
echo "Crate Prefix: $CRATE_PREFIX"
echo "If it does not appear immediately, relaunch Finder."