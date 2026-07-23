# Security Policy

EZLibrary writes to a DJ's Serato library and modifies audio files, so security
and data integrity are taken seriously. This document explains how to report
problems and what you can expect in return.

## Reporting a vulnerability or data-loss bug

**Please do not open a public issue for security or data-loss vulnerabilities.**
Public disclosure before a fix is available puts other users at risk.

Instead, report it privately through one of these channels:

- **GitHub private advisory:** open a draft security advisory at
  <https://github.com/tawaunl/EZLibrary/security/advisories/new> (preferred).
- **Direct contact:** reach the maintainer privately via the contact listed on the
  [GitHub profile](https://github.com/tawaunl).

Please include, where possible:

- A description of the issue and its impact.
- Steps to reproduce (against a **disposable** Serato library, never your primary
  one).
- The EZLibrary version, macOS version, and hardware (Apple Silicon / Intel).
- Any relevant logs (update logs live at `~/Library/Logs/EZLibrary-Update.log`).

### What to expect

- **Acknowledgement** of your report as promptly as possible.
- An honest assessment of severity and a plan for a fix.
- Credit in the release notes / changelog for the fix, unless you prefer to remain
  anonymous.

This is an open, community project. There is **no paid bug bounty** at this time,
but security and data-integrity reports are the highest-priority issues in the
tracker, and responsible disclosure is genuinely appreciated.

## Scope

In scope:

- Data loss or corruption of `database V2`, `.crate` files, or audio files.
- Failures in the backup / atomic-write / verification pipeline described in
  [docs/SECURITY_AND_DATA_HANDLING.md](docs/SECURITY_AND_DATA_HANDLING.md).
- Unexpected network exfiltration of library data.
- Privilege-escalation or arbitrary-code-execution issues in the app, installer,
  or Finder Quick Action.

Out of scope:

- Bugs in Serato itself or other third-party apps.
- Issues that require an already-compromised machine or physical access.
- Non-security functional bugs — please file those as a normal
  [bug report](https://github.com/tawaunl/EZLibrary/issues/new/choose).

## How EZLibrary protects your library

For a detailed, code-referenced explanation of what is backed up before writes,
what is atomic, and what happens if a write fails midway, see
[docs/SECURITY_AND_DATA_HANDLING.md](docs/SECURITY_AND_DATA_HANDLING.md).

## Supported versions

EZLibrary is actively maintained. Security and data-integrity fixes target the
**latest released version**. Please update to the newest release (via
**Check for Updates…** in the app) before reporting, in case the issue is already
fixed.
