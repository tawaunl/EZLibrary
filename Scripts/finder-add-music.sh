#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
APP_RESOURCE_DIR="$ROOT_DIR"
REPO_ROOT="$ROOT_DIR"

MODE="${EZLIBRARY_ADD_MODE:-${SERATOTOOLS_ADD_MODE:-move}}"
DESTINATION="${EZLIBRARY_ADD_DESTINATION:-${SERATOTOOLS_ADD_DESTINATION:-$HOME/Music}}"
CRATE_PREFIX="${EZLIBRARY_ADD_CRATE_PREFIX:-${SERATOTOOLS_ADD_CRATE_PREFIX:-New Music}}"
LIBRARY_DIR="${EZLIBRARY_LIBRARY_DIR:-${SERATOTOOLS_LIBRARY_DIR:-}}"

if [[ "$#" -eq 0 ]]; then
  echo "No Finder input received." >&2
  exit 2
fi

resolve_cli_binary() {
  local cli_override="${EZLIBRARY_CLI_PATH:-${SERATOTOOLS_CLI_PATH:-}}"
  if [[ -n "$cli_override" && -x "$cli_override" ]]; then
    echo "$cli_override"
    return
  fi

  local bundled_cli="$APP_RESOURCE_DIR/bin/EZLibraryCLI"
  if [[ -x "$bundled_cli" ]]; then
    echo "$bundled_cli"
    return
  fi

  if [[ -f "$REPO_ROOT/Package.swift" ]]; then
    cd "$REPO_ROOT"
    if CLI_BIN_PATH="$(swift build --product EZLibraryCLI --show-bin-path 2>/dev/null)"; then
      local cli_candidate="$CLI_BIN_PATH/EZLibraryCLI"
      if [[ -x "$cli_candidate" ]]; then
        echo "$cli_candidate"
        return
      fi
    fi
  fi

  echo ""
}

CLI_BIN="$(resolve_cli_binary)"

if [[ -n "$CLI_BIN" && -x "$CLI_BIN" ]]; then
  cmd=("$CLI_BIN" --mode "$MODE" --destination "$DESTINATION" --crate-prefix "$CRATE_PREFIX")
elif [[ -f "$REPO_ROOT/Package.swift" ]]; then
  cd "$REPO_ROOT"
  cmd=(swift run --quiet EZLibraryCLI --mode "$MODE" --destination "$DESTINATION" --crate-prefix "$CRATE_PREFIX")
else
  echo "EZLibraryCLI was not found. Reinstall EZLibrary or set EZLIBRARY_CLI_PATH." >&2
  exit 3
fi

if [[ -n "$LIBRARY_DIR" ]]; then
  cmd+=(--library-dir "$LIBRARY_DIR")
fi

cmd+=(--)
for path in "$@"; do
  cmd+=("$path")
done

"${cmd[@]}"