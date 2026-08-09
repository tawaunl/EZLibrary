#!/bin/bash
# Notarizes a signed .pkg with Apple and staples the result to it.
#
# Signing alone is not enough to clear Gatekeeper on a machine that has never
# seen the app: since macOS 10.15 the first launch of a downloaded app is also
# checked against Apple's notarization service. Stapling attaches the ticket to
# the package itself, so the check passes even if the user is offline.
#
# Usage:
#   ./Scripts/notarize.sh dist/EZLibrary-1.0.1.pkg
#
# Credentials, in resolution order:
#   1. $EZLIBRARY_NOTARY_PROFILE — a keychain profile name (default: EZLibrary).
#      Create it once with:
#        xcrun notarytool store-credentials EZLibrary \
#          --apple-id you@example.com --team-id TEAMID --password <app-specific-password>
#      or, with an App Store Connect API key:
#        xcrun notarytool store-credentials EZLibrary \
#          --key AuthKey_XXXX.p8 --key-id XXXX --issuer <issuer-uuid>
#   2. $EZLIBRARY_NOTARY_KEY / _KEY_ID / _ISSUER — an API key passed directly,
#      for CI, where there is no keychain to store a profile in.
set -euo pipefail

PKG_PATH="${1:-}"

if [[ -z "$PKG_PATH" ]]; then
  echo "Usage: $0 <path-to-pkg>" >&2
  exit 1
fi

if [[ ! -f "$PKG_PATH" ]]; then
  echo "Error: package not found: $PKG_PATH" >&2
  exit 1
fi

# A package that was never signed cannot be notarized, and the failure Apple
# returns for it is far less clear than saying so here.
if ! pkgutil --check-signature "$PKG_PATH" >/dev/null 2>&1; then
  echo "Error: $PKG_PATH is not signed, so it cannot be notarized." >&2
  echo "       Install a 'Developer ID Installer' certificate and rebuild." >&2
  exit 1
fi

NOTARY_ARGS=()
PROFILE="${EZLIBRARY_NOTARY_PROFILE:-EZLibrary}"

if [[ -n "${EZLIBRARY_NOTARY_KEY:-}" ]]; then
  NOTARY_ARGS=(
    --key "$EZLIBRARY_NOTARY_KEY"
    --key-id "${EZLIBRARY_NOTARY_KEY_ID:?EZLIBRARY_NOTARY_KEY_ID is required with EZLIBRARY_NOTARY_KEY}"
    --issuer "${EZLIBRARY_NOTARY_ISSUER:?EZLIBRARY_NOTARY_ISSUER is required with EZLIBRARY_NOTARY_KEY}"
  )
  echo "Notarizing with an App Store Connect API key..."
else
  # `notarytool history` is the cheapest call that proves the profile exists and
  # its credentials still work. Finding out after a multi-minute upload that the
  # password was revoked is a bad way to learn it.
  if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    echo "Error: no working notarization credentials for keychain profile '$PROFILE'." >&2
    echo "" >&2
    echo "Store them once with:" >&2
    echo "  xcrun notarytool store-credentials $PROFILE \\" >&2
    echo "    --apple-id <your-apple-id> --team-id <TEAMID> --password <app-specific-password>" >&2
    echo "" >&2
    echo "The password is an app-specific password from appleid.apple.com, not" >&2
    echo "your Apple ID password." >&2
    exit 1
  fi
  NOTARY_ARGS=(--keychain-profile "$PROFILE")
  echo "Notarizing with keychain profile '$PROFILE'..."
fi

echo "Submitting $(basename "$PKG_PATH") — this usually takes a few minutes."

# --wait blocks until Apple reaches a verdict. Without it the command returns a
# submission ID and the staple below would run against a ticket that does not
# exist yet.
SUBMIT_LOG="$(mktemp)"
trap 'rm -f "$SUBMIT_LOG"' EXIT

if ! xcrun notarytool submit "$PKG_PATH" "${NOTARY_ARGS[@]}" --wait 2>&1 | tee "$SUBMIT_LOG"; then
  echo "Error: notarization submission failed." >&2
  exit 1
fi

# notarytool exits 0 for a completed submission even when the verdict is
# "Invalid", so the status has to be read out of the output rather than trusted
# to the exit code.
if ! grep -q "status: Accepted" "$SUBMIT_LOG"; then
  SUBMISSION_ID="$(sed -n 's/.*id: \([0-9a-f-]\{36\}\).*/\1/p' "$SUBMIT_LOG" | head -1)"
  echo "" >&2
  echo "Error: Apple did not accept this build." >&2
  if [[ -n "$SUBMISSION_ID" ]]; then
    echo "Full log:" >&2
    xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_ARGS[@]}" >&2 || true
  fi
  exit 1
fi

# Stapling writes the ticket into the package so Gatekeeper can verify it
# without a network round trip on the user's machine.
echo "Stapling the ticket to the package..."
xcrun stapler staple "$PKG_PATH"
xcrun stapler validate "$PKG_PATH"

echo ""
echo "Notarized and stapled: $PKG_PATH"
