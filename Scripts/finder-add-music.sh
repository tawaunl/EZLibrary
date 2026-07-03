#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODE="${SERATOTOOLS_ADD_MODE:-move}"
DESTINATION="${SERATOTOOLS_ADD_DESTINATION:-$HOME/Music}"
CRATE_PREFIX="${SERATOTOOLS_ADD_CRATE_PREFIX:-New Music}"
LIBRARY_DIR="${SERATOTOOLS_LIBRARY_DIR:-}"

if [[ "$#" -eq 0 ]]; then
  echo "No Finder input received." >&2
  exit 2
fi

cd "$ROOT_DIR"

if CLI_BIN_PATH="$(swift build --product SeratoToolsCLI --show-bin-path 2>/dev/null)"; then
  CLI_BIN="$CLI_BIN_PATH/SeratoToolsCLI"
else
  CLI_BIN=""
fi

if [[ -n "$CLI_BIN" && -x "$CLI_BIN" ]]; then
  cmd=("$CLI_BIN" --mode "$MODE" --destination "$DESTINATION" --crate-prefix "$CRATE_PREFIX")
else
  cmd=(swift run --quiet SeratoToolsCLI --mode "$MODE" --destination "$DESTINATION" --crate-prefix "$CRATE_PREFIX")
fi

if [[ -n "$LIBRARY_DIR" ]]; then
  cmd+=(--library-dir "$LIBRARY_DIR")
fi

cmd+=(--)
for path in "$@"; do
  cmd+=("$path")
done

"${cmd[@]}"