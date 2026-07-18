# Finder Quick Action: Add Music

This project now includes a command-line importer and helper script so Finder
right-click imports can flow into EZLibrary.

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

## Install from packaged app (no source checkout)

If EZLibrary was installed to `/Applications/EZLibrary.app`, run:

```bash
/Applications/EZLibrary.app/Contents/Resources/scripts/install-finder-quick-action.sh
```

This uses the bundled `EZLibraryCLI` binary, so users do not need Swift or source files.

## Manual setup (fallback)

If you prefer manual setup, use Automator and call `Scripts/finder-add-music.sh` with input passed as arguments.

## Configuration via environment variables

- `EZLIBRARY_ADD_MODE`: `move` or `copy` (default `move`)
- `EZLIBRARY_ADD_DESTINATION`: destination main music folder (default `~/Music`)
- `EZLIBRARY_ADD_CRATE_PREFIX`: crate prefix before date (default `New Music`)
- `EZLIBRARY_LIBRARY_DIR`: optional explicit `_Serato_` directory override

> Legacy `SERATOTOOLS_*` variable names are still honored as a fallback, so existing Quick Actions keep working.

Example custom install:

```bash
EZLIBRARY_ADD_MODE=copy \
EZLIBRARY_ADD_DESTINATION="$HOME/Music" \
EZLIBRARY_ADD_CRATE_PREFIX="Promo Imports" \
./Scripts/install-finder-quick-action.sh
```

## Direct CLI usage

From repository root:

```bash
swift run EZLibraryCLI --mode move --destination "$HOME/Music" --crate-prefix "New Music" -- ~/Downloads/incoming
```
