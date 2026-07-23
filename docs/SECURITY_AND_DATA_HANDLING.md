# Security and Data Handling

EZLibrary reads and writes files in your Serato library — the `database V2` and
`.crate` files (typically under `~/Music/_Serato_`) as well as ID3 tags inside your
audio files. Because these files are irreplaceable, safety is a first-class design
goal, not an afterthought. This document explains what the app touches, how it
protects your data, and what you should know before running it.

Every technical claim below maps to code you can read in
[`Sources/EZLibraryCore/Safety/`](../Sources/EZLibraryCore/Safety) and
[`Sources/EZLibraryCore/Writers/`](../Sources/EZLibraryCore/Writers). To report a
security vulnerability privately, see [SECURITY.md](../SECURITY.md).

## What EZLibrary accesses

- Your Serato library database and crate files (typically under `~/Music/_Serato_`)
- Audio files you choose to import, tag, or move
- Optional: Discogs and AcoustID APIs for metadata lookup, only when you provide
  your own API token/key (`EZLIBRARY_DISCOGS_TOKEN` / `EZLIBRARY_ACOUSTID_KEY`)
- Optional: YouTube / SoundCloud links you provide, only when you use the
  Download Audio feature

EZLibrary does not send your library data, file paths, or metadata to any server
controlled by this project. Metadata lookups go directly from your machine to the
third-party service you've configured (Discogs, AcoustID), using your own
credentials. Core library operations do not require network access.

## How writes are protected (at a glance)

Every operation that modifies your library data follows the same safety pattern:

1. **Backup first.** Before any write, EZLibrary snapshots the target Serato file,
   and before bulk operations you can create a full timestamped backup that you
   preview first.
2. **Atomic writes.** Files are written to a temporary location and swapped into
   place only once the write completes successfully, so a crash can't leave a
   half-written file.
3. **Read-back verification.** After a metadata write, EZLibrary re-reads what it
   wrote and confirms it persisted before reporting success.
4. **Explicit confirmation for sensitive operations.** Bulk edits, consolidation,
   and missing-track fixes require you to review and confirm scope. Nothing
   silently auto-repairs your library in the background.
5. **Readable failure messages.** Failures surface a specific, human-readable error
   instead of failing silently or leaving you to guess what happened.

The rest of this document explains each of these in detail.

## The write pipeline (in detail)

Every mutation of a Serato file goes through the same ordered pipeline:

1. **Refuse to write while Serato is running.** Metadata edits check
   [`SeratoProcessGuard`](../Sources/EZLibraryCore/Safety/SeratoProcessGuard.swift).
   Serato rewrites `database V2` from its own in-memory library when it quits, so
   writing while it is open risks Serato clobbering your change (or orphaning a
   renamed file). EZLibrary stops and asks you to quit Serato first.
2. **Write the audio file's ID3 tags first.** For metadata edits, on-disk file
   tags are written before the database is touched, so EZLibrary never commits a
   database-only change when the file-tag write fails.
3. **Snapshot the file before touching it.** Immediately before any mutation,
   [`SeratoBackupBeforeWrite`](../Sources/EZLibraryCore/Safety/SeratoBackupBeforeWrite.swift)
   copies the target file to a timestamped shadow copy (details below).
4. **Write atomically.** The new contents are written through
   [`AtomicFileWriter`](../Sources/EZLibraryCore/Safety/AtomicFileWriter.swift),
   which writes to a temporary file and then atomically replaces the original.
5. **Read back and verify.** After a metadata write, EZLibrary re-reads the bytes
   it just wrote and confirms the change actually persisted before reporting
   success. If verification fails, it raises an error instead of claiming a
   phantom success.

## What gets backed up before writes

Before any write, EZLibrary copies the target Serato file to a **pre-write shadow
snapshot**:

- **Location:** `~/Library/Application Support/SeratoTools/Backups/pre-write/`
- **Naming:** each snapshot is prefixed with an ISO-8601 timestamp, e.g.
  `2026-07-22T14-03-51.204Z-database V2`.
- **Retention:** the most recent **20** snapshots per source file are kept; older
  ones are pruned automatically.

This is a safety net that is separate from — and in addition to — the user-facing
**Backup** feature. It happens automatically for every write, so even a routine
metadata edit leaves a recoverable copy of the previous state.

### The user-facing Backup feature

On top of the automatic pre-write snapshots, EZLibrary's **Backup** view
([`LibraryBackupService`](../Sources/EZLibraryCore/Services/LibraryBackupService.swift))
lets you make deliberate, timestamped backups in a `SeratoBackups` folder at a
destination you choose, in three modes:

| Mode | What it captures |
|---|---|
| **Full** | The whole library and all referenced tracks. |
| **Incremental** | Only what changed since the previous backup. |
| **Single-crate** | One crate and the files it references. |

You can preview the size and scope of a backup before committing to it.

## What "atomic" means here

`AtomicFileWriter` never writes in place. It:

1. writes the new contents to a temporary file in the same directory,
2. flushes it to disk, then
3. atomically replaces the original with the temporary file.

A crash, kernel panic, or power loss mid-write can therefore never leave a
truncated or half-written `database V2` / `.crate` file. You either have the
complete old file or the complete new file — never a corrupt in-between state.

## What happens if a write fails midway

EZLibrary is designed to fail safe:

- **The original is never partially overwritten.** Because writes are atomic, a
  failure during the write leaves the original file fully intact, and the
  temporary file is deleted.
- **File renames are rolled back.** If a metadata edit renamed the audio file and
  a later step fails, the file is moved back to its original path so the database
  and the file stay in sync.
- **Verification failures are surfaced, not swallowed.** If the read-back check
  can't confirm the change, EZLibrary raises a clear, human-readable error rather
  than silently reporting success.
- **Missing files don't abort a whole batch.** Backups and bulk edits skip files
  that have been moved or deleted and continue with the rest, reporting what was
  skipped.
- **Cover art and other tags are preserved.** ID3 writes preserve existing
  artwork and non-edited frames instead of wiping the tag.

## Recovering from a bad write

If something ever looks wrong after a write:

1. Quit Serato.
2. Open `~/Library/Application Support/SeratoTools/Backups/pre-write/`.
3. Find the most recent snapshot of `database V2` (or the relevant `.crate`) taken
   just before your change.
4. Copy it back over the file in your `_Serato_` folder.
5. Reopen Serato.

If you used the Backup view, restore from the corresponding timestamped backup in
your `SeratoBackups` folder instead.

## What to do before trusting this (or any) tool with your library

- Keep your own independent backup of `~/Music/_Serato_` before running any bulk
  operation, regardless of what any tool claims about safety.
- Check the commit history and test coverage of any library-management tool before
  granting it write access.
- Review what third-party services a tool talks to, and whether it's sending your
  data anywhere you didn't explicitly authorize.

## Known risk areas

- **Download Audio feature**: downloads audio via `yt-dlp` based on YouTube /
  SoundCloud links you provide. This is a distinct workflow from library management
  and doesn't touch your existing crates directly, but you should only use it with
  content you have the rights to.
- **Third-party API keys**: if you configure a Discogs or AcoustID token, that key
  is stored locally and used only for the lookups you trigger. Treat it like any
  other credential.

## What EZLibrary does *not* do

- It does not phone home or send your library anywhere. Online lookups (metadata,
  purchase links) are opt-in, per-action, and send only the search terms needed for
  that lookup.
- It does not silently auto-repair missing tracks. Missing-track fixes require an
  explicit action from you.
- It does not require network access for core library operations.

## Reporting a security or data issue

- **Security vulnerabilities or unintended data-exposure risks** — please report
  privately and do **not** open a public issue. See [SECURITY.md](../SECURITY.md).
- **Non-sensitive data-safety bugs** (loss or corruption) — open an issue at
  <https://github.com/tawaunl/EZLibrary/issues> with as much detail as possible.

Data-safety issues are treated as the highest priority, above feature requests.
