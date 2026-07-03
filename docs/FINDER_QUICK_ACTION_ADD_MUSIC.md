# Finder Quick Action: Add Music

This project now includes a command-line importer and helper script so Finder
right-click imports can flow into SeratoTools.

## What it does

- Accepts selected files and/or folders from Finder.
- Imports supported audio formats (`mp3`, `m4a`, `aac`, `wav`, `aif`, `aiff`, `flac`, `alac`, `ogg`) into your main music folder.
- Creates a dated crate in your Serato `Subcrates` folder.
- Runs while Serato is open for quick add workflow.

## Automatic install (recommended)

From repository root:

```bash
./Scripts/install-finder-quick-action.sh
```

This creates `~/Library/Services/Add To Serato Library.workflow` automatically.

After install, right-click any files/folders in Finder and run `Quick Actions` -> `Add To Serato Library`.

If the action does not appear immediately, relaunch Finder.

## Manual setup (fallback)

If you prefer manual setup, use Automator and call `Scripts/finder-add-music.sh` with input passed as arguments.

## Configuration via environment variables

- `SERATOTOOLS_ADD_MODE`: `move` or `copy` (default `move`)
- `SERATOTOOLS_ADD_DESTINATION`: destination main music folder (default `~/Music`)
- `SERATOTOOLS_ADD_CRATE_PREFIX`: crate prefix before date (default `New Music`)
- `SERATOTOOLS_LIBRARY_DIR`: optional explicit `_Serato_` directory override

Example custom install:

```bash
SERATOTOOLS_ADD_MODE=copy \
SERATOTOOLS_ADD_DESTINATION="$HOME/Music" \
SERATOTOOLS_ADD_CRATE_PREFIX="Promo Imports" \
./Scripts/install-finder-quick-action.sh
```

## Direct CLI usage

From repository root:

```bash
swift run SeratoToolsCLI --mode move --destination "$HOME/Music" --crate-prefix "New Music" -- ~/Downloads/incoming
```
