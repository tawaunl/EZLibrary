# EZLibrary Feature Roadmap

## Status at a glance (updated 2026-08-19)

Legend: ✅ Done (shipped) · 🚧 In progress / partial · 📋 Planned · ⏸️ Tabled

The app has grown well past the original MVP, and most of the originally-planned features are shipped, plus a number of features that weren't in the original 11.

### In progress

- 🚧 **ID3 title descriptor preservation** — keep DJ markers like "(Intro)"/"(Clean)" when applying an online title match (branch `feature/id3-title-descriptors`, PR #16).
- 🚧 **Offline library sync** — browse the library and queue edits from a phone while away from the Mac (branch `feature/offline-library-sync`). Stage 0 engine work landed; see [Offline library sync](#offline-library-sync) below.

### Planned / not started

- 📋 Feature 6 **Switch**, Feature 8 **iTunes Migration**, Feature 11 **Rekordbox + cross-platform transfer** (tracks, cues, crates)
- 📋 Feature 7 continuous **Misplaced-Tracks watcher** (FSEvents `DirectoryWatcher`)
- 📋 Dedicated **cue-point editor** (Feature 10 cues)
- 📋 **Windows support** (cross-platform app/runtime support beyond macOS)

### Next steps (forward-looking)

Candidate next work, roughly in priority order:

1. **Finish in-progress:** land the ID3 title-descriptor-preservation change (PR #16).
2. **Feature 7 — Misplaced Tracks (full):** add the FSEvents `DirectoryWatcher` for continuous detection, building on the shipped Consolidation/`LibraryFolderSyncService`.
3. **Feature 10 — Cue-point editor:** cues are preserved today; a dedicated editor is the remaining gap.
4. **Feature 8 — iTunes Migration:** `Library.xml` reader → crates (isolated, one-time-per-user tool).
5. **Feature 6 — Switch** and **Feature 11 — Rekordbox + cross-platform transfer:** add reliable transfer of tracks, cues, and crates between Serato and Rekordbox; highest reverse-engineering risk, so schedule last.
6. **Windows support:** scope and sequence cross-platform runtime, filesystem, and packaging work needed to support Windows.
7. **Revisit tabled Record Pool Search** if a more reliable pool search surfaces (see below).

### Tabled

- ⏸️ **Record Pool Search** (BPM Supreme / DJcity) — see "Tabled / future exploration" at the bottom.

---

## Context (original plan)

The skeleton macOS SwiftUI app (`EZLibraryCore` + `EZLibraryApp`) is in place and launches successfully. The user wants to build out 11 features (Add New Music, Missing Tracks, CrateView, Find Duplicates, CrateMatch, Switch, Misplaced Tracks, iTunes Migration, Backup, Tags & Cues, Sync/Rekordbox). Building all 11 at once isn't practical — they share infrastructure but vary hugely in risk (some are pure local file work, others require reverse-engineering third-party formats or external APIs). This plan lays out feature sequencing and an MVP recommendation, and defers the most speculative work (audio fingerprinting, Rekordbox export, Spotify/iTunes integration) until core product flows are proven.

Decisions already confirmed with the user: macOS-only (the Windows mention in Feature 1's spec is leftover boilerplate, ignored), native Swift/SwiftUI, and the user delegated MVP/phase selection to us.

Project rule reference: see `docs/ENGINEERING_RULES.md` for code standards that apply across all phases, including the requirement that new user-facing errors must be human-readable.

**Note on research method**: to validate the plan's format assumptions, I had an agent inspect the real (if mostly empty) `~/Music/_Serato_/` files already on this machine — `database V2` and `Subcrates/*.crate` — read-only, to confirm the binary layout before we design around it. Findings below (UTF-16BE strings, the real nesting delimiter) came from that inspection.

## Two corrections to the original feature spec

1. **String encoding**: `database V2` fields are length-prefixed **UTF-16BE**, not ASCII/UTF-8. The parser/writer must decode/encode accordingly.
2. **Subcrate nesting delimiter**: real Serato files use the Unicode glyph **`≫≫`** (U+226B doubled) to separate parent/child crate names in a filename, not the ASCII `%%` mentioned in the brief. Hierarchy building must split on `≫≫`.

Only the file header/envelope was validated on this machine (the local library is empty of tracks) — before trusting the writer against a real user's data, we need a populated library or fixture to validate the full record schema (`otrk`/`pfil`/`tsng`/`tart`/`tbpm`/`tkey`, plus crate track-membership tags).

> **Update:** binary read/write behavior has been validated against a real, populated 1343-track library (see `Tests/EZLibraryCoreTests/Fixtures/RealLibrarySample/`), including a byte-exact path-rewrite round-trip.

## Phase order

> **Actual progress (development didn't strictly follow this order):** Phase 1 ✅ (CrateView, Missing Tracks) · Phase 2 ✅ Add Music / 🚧 Switch & Misplaced Tracks partial · Phase 3 ✅ (Find Duplicates) · Phase 4 ✅ (Backup) · Phase 5 ✅ Tags / 🚧 Cues · Phase 6 ✅ (CrateMatch → PlaylistMatch) · Phase 7 📋 (iTunes Migration) · Phase 8 📋 (Rekordbox Sync). The table below is the original plan.

| Phase | Features | Key implementation focus | Why here |
|---|---|---|---|
| 1 (**MVP**) | 3 CrateView, 2 Missing Tracks | CrateHierarchy, FileSystemScanner, SeratoPathRewriter | Read/metadata-only — no audio file ever moved/deleted — so bugs are low-blast-radius. Immediately useful to any Serato DJ. No third-party formats, no extensions, works entirely with plain `swift build` today. |
| 2 | 1 Add New Music, 6 Switch, 7 Misplaced Tracks | TrackFileMover, DirectoryWatcher | First phase that moves actual audio files; deliberately after path-rewrite plumbing is proven on metadata-only Phase 1. Feature 1 needs a Finder Sync Extension decision here (see Risks) — plain SwiftPM can't build `.appex` targets, so this is where we likely need full Xcode. |
| 3 | 4 Find Duplicates | Fingerprinting/ engine, real use of Licensing/ | Audio fingerprinting is a new, isolated domain (Chromaprint via C-interop vs custom FFT) — worth spiking early once file-move plumbing exists, but isolated enough not to block anything else. |
| 4 | 9 Backup | Snapshot/restore atop existing write-safety primitives | Placed after real mutation history exists (Phases 1-3) so there's something worth protecting, before riskier external-integration phases begin. |
| 5 | 10 Tags & Cues | ID3 read/write, cue-point tag format (new reverse-engineering pass), offline suggestion DB | MP3-only scope keeps this contained. |
| 6 | 5 CrateMatch | Spotify ingestion, fuzzy metadata matching | Reuses matching concepts from Phase 3; needs Spotify API credentials decision. |
| 7 | 8 iTunes Migration | Library.xml (or MediaLibrary framework) reader | One-time-per-user tool, isolated risk, doesn't block others — reuses TrackFileMover/SeratoCrateWriter, no new file-move primitives. |
| 8 | 11 Sync (Rekordbox) | Rekordbox DB writer, cue→hot-cue conversion, USB export | Highest reverse-engineering risk in the roadmap; pure read-only export from our side (never writes back to Serato), so it can slip without blocking anything. Target the unencrypted `.PDB`/USB-export format first (also what CDJs actually read), not the SQLCipher-encrypted `master.db` — safer and may fully satisfy the "mirror to USB" requirement on its own. |

---

## Offline library sync

**Goal:** browse the library, retag tracks, and build crates from a phone while away from the
Mac — then apply that work safely on return.

**Shape:** the phone plans, the Mac executes. A dated `LibrarySnapshot` goes out; an intent
queue comes back; the Mac revalidates it against a fresh parse, previews a diff, and only
then writes through the existing backup-first/atomic/read-back path. The phone never touches
a Serato file, so it cannot corrupt anything.

**Why it is tractable:** the library's metadata is ~1.76 MB against ~18 GB of audio, so this
was never a sync-capacity problem — only a question of which operations can be expressed
without the audio bytes present. Browsing, crate membership, and tag *values* can; playback,
waveforms, fingerprinting, and the actual ID3 write cannot.

**Transport:** a plain iCloud Drive folder, not CloudKit. CloudKit needs a Developer ID
provisioning profile, and Gatekeeper checks that profile at every launch — an expired one
stops the app opening, which is unacceptable for a tool people install and forget. One writer
per file (`snapshot-<fingerprint>.json` from the Mac, `queue-<uuid>.json` from the phone) so
iCloud never creates conflict copies. Being just files, it degrades to Dropbox or AirDrop.

### Track identity

`Track.id` is a fresh `UUID()` per parse and means nothing across devices, so identity runs on
`seratoStoredPath`. Paths are not permanent either, so `TrackIdentityResolver` walks a ladder
and reports which rung answered:

1. **Exact path** — free and exact.
2. **Rename journal** — an exact lookup for any move EZLibrary itself performed.
3. **Filename basename** — consolidation preserves filenames while changing folders.
4. **Snapshot title + artist** — survives a move *and* a rename.
5. **Unresolved / ambiguous** — surfaced for the user, never guessed.

Measured against the real 2,362-track library, `(dateAdded, duration)` looked like the ideal
key — immune to both moves and retagging — but **fails**: 370 tracks are ambiguous under it
across 83 collision groups, because batch imports share a `uadd` second, and 280 tracks carry
no duration at all. Path, basename, and title+artist were each unique across that library,
though that is a property of one library and not a guarantee — hence the corroboration step
and the explicit ambiguous case.

### Reconciliation

Everything is dated, so an incoming intent falls into one of four buckets: the journal never
touched it (apply), the journal set the same value (drop silently — do not prompt on
agreement), the journal set a different value (a real conflict, ask), or the value differs
with nothing in the journal to explain it (external change by Serato or Finder — ask, but
there is no second value to offer). Crate membership is a set and merges on its own; only
crate *ordering* genuinely needs a prompt.

Retention matters: pruning the journal past a snapshot's timestamp makes that snapshot
unreconcilable. Journal entries are kept for `LibraryChangeJournal.defaultRetention`
(90 days), and older work is refused rather than guessed at.

### Status

| Stage | Scope | Status |
|---|---|---|
| 0 | `Codable` snapshot + journal + resolver, engine only | ✅ landed |
| 1a | Snapshot export from the Mac ("Offline Sync" tab) | ✅ landed |
| 1b | Read-only browsing on the phone (needs an iOS app target) | 📋 next |
| 2 | Crate intents (create, add, remove, reorder) | 📋 |
| 3 | Queued tag edits with three-way merge | 📋 |

Stage 0 shipped `Sources/EZLibraryCore/Sync/` — `LibrarySnapshot`, `LibrarySnapshotBuilder`,
`LibraryFingerprint`, `LibraryChangeJournal`, `TrackIdentityResolver` — plus journaling wired
into `LibraryConsolidationService`, covered by 45 tests.

Stage 1a shipped `LibrarySnapshotExportService` and the "Offline Sync" tab: exports to a
folder (defaulting to iCloud Drive), skips the write when the fingerprint is unchanged, and
keeps the most recent few snapshots so a device that has been offline can still find the one
its pending work was based on.

**Stage 1b is blocked on iOS portability, which is larger than first estimated.** Building
`EZLibraryCore` against the iOS SDK surfaces two distinct problems across 12 files:

- `Process` is unavailable on iOS — 6 service files shell out to Homebrew, fpcalc, yt-dlp and
  ffmpeg. Those features are macOS-only by nature, but 4 other Core files depend on
  `AudioFingerprintService` alone, so guarding them cascades.
- `FileManager.homeDirectoryForCurrentUser` is unavailable on iOS — used by
  `SeratoLibraryLocator`, `SeratoLocationDatabase`, `LibraryConsolidationService`,
  `SeratoLocationRepairService`, and `FileSystemScanner`. All are Mac-side concerns: a phone
  reads a snapshot and never locates a Serato library at all.

Two ways forward:

1. **`#if os(macOS)` guards** — ~16 files, one target. Cheaper now, but conditional
   compilation only ever gets built in one configuration on CI, so the iOS path rots quietly.
2. **Split a portable `EZLibraryShared` target** — Models, `Sync/`, `AtomicFileWriter`,
   `CrateHierarchy`, `TrackTextSearch`; all verified pure-Foundation. Costs a one-line
   `import` in ~37 Core files, but portability becomes structural and compiler-enforced, and
   the iOS app depends on a small pure module instead of a large one full of dead branches.
   `LibraryFingerprint` stays in Core, since it needs the library layout.

Only `SeratoProcessGuard` is guarded so far (`#if os(macOS)`, returning `false` elsewhere —
Serato is a desktop app, so nothing on a phone can be holding the library open). `.iOS` is
deliberately *not* declared in `Package.swift` until Core actually compiles for it.

## Key open risks per feature (decide when that phase starts, not now)

- **Feature 1** ✅ resolved: shipped a **Finder Quick Action** ("Add to EZLibrary") instead of a Finder Sync Extension — no `.appex`/Xcode project needed.
- **Feature 4** ✅ resolved: fingerprinting uses **`fpcalc` (Chromaprint)** via `AudioFingerprintService` (Homebrew-managed), not a custom FFT.
- **Feature 5** ✅ resolved differently: Spotify's anonymous token/API is blocked, so PlaylistMatch reads the **embed page `__NEXT_DATA__`** JSON (Apple Music + CSV supported too).
- **Feature 8** 📋 open: `Library.xml` (needs user to enable "Share Library XML" in Music.app) recommended over Apple's semi-private `MediaLibrary` framework.
- **Feature 10** 🚧 partial: ID3 read/write is done in pure Swift (Serato cues/beatgrids preserved); a dedicated **cue-point tag editor** still needs its own format research pass.
- **Feature 11** 📋 open: target Rekordbox's unencrypted `.PDB` format, not encrypted `master.db` (legally/technically riskier, breaks on Pioneer updates).
- **Cross-cutting** ✅ resolved: tests run via the `runTests` tooling / Xcode; correctness validated against the real-library fixture in `Tests/EZLibraryCoreTests/Fixtures/`.

## Tabled / future exploration

### Record Pool Search (BPM Supreme / DJcity) — tabled 2026-07-18

**Idea:** In PlaylistMatch, for a track the user can't buy, let a subscriber search the DJ record pools they already pay for (BPM Supreme, DJcity) from inside the app and jump straight to the download page. Would sit as a "Your pools" row next to the iTunes/Beatport Buy links.

**Status:** Fully prototyped end-to-end, then **removed from the codebase** because it wasn't reliable enough to ship. Code lives in git history on branch `feature/record-pool-search` (commits `16778c7`, `db8df63`); removal is `2f45701`. Verified integration details are captured in repo memory (`/memories/repo/notes.md`).

**What worked:**
- Secure design: credentials/token in the macOS **Keychain** only (never logged), sent over HTTPS to the pool only.
- **One-click sign-in** via an embedded `WKWebView` that auto-captures the `Authorization: Bearer` token the site sends (no DevTools/paste for the user).
- BPM Supreme API confirmed: `GET api.download.bpmsupreme.com/v1/albums?term=<title>` with a Bearer UUID device-token; each result is an album (title/artist/`pool_url` + `media[].version`).
- Order-independent artist matching (ignoring `ft`/`feat`/`with`/`&`) correctly confirmed collab tracks.

**Why it was tabled (the blocker):** BPM's `term` search is too fuzzy to be dependable. Common-word titles ("Walk", "Radio", "ghost", "NOBLE") return 50–100 results that match on **artist-name substrings** ("Radio Slave", "Walk Off The Earth", "HAVEN.") with the *exact* track absent, and many tracks return zero results. Adding the artist to the query makes BPM return **nothing** (`raw=0`), and raising the limit to 100 didn't surface the missing tracks. Net: it reliably found direct/collab hits by well-known artists but missed a large fraction of a real playlist, which felt broken.

**To revive later, investigate:**
- A better/stricter BPM search endpoint or params than `/v1/albums?term=` (the site's search fans out to several endpoints; find the one that ranks exact title matches first).
- DJcity's real search endpoints (never verified — its provider was a best-effort stub).
- Whether a fuzzy pre-filter + a second confirmation pass (e.g. compare BPM `bpm`/`key`/duration) can rescue the ambiguous common-title cases.
- ToS/rate-limit posture for automated per-track search across a large playlist.

## Completed work (shipped)

### Original 11 features (full status reference)

| # | Feature | Status | Where it lives / notes |
|---|---|---|---|
| 1 | Add New Music | ✅ Done | "Add Music" tab (`AddMusicView`/`AddMusicImportService`) + Finder Quick Action; import with primary + secondary crate assignment |
| 2 | Missing Tracks | ✅ Done | "Missing Tracks" tab (`MissingTracksView`/`MissingTracksService`); scan + relink candidates |
| 3 | CrateView | ✅ Done | "Crates" tab (`CrateTreeView` + `CrateDetailView` + `TrackTableView`), hidden-crate support |
| 4 | Find Duplicates | ✅ Done | "Duplicates" tab; completeness scoring, keep-best, delete → Library/Computer; `AudioFingerprintService` (fpcalc) |
| 5 | CrateMatch | ✅ Done | shipped as **PlaylistMatch**: Spotify/Apple/CSV → crate, buy-first purchase links (iTunes/Beatport), YouTube/SoundCloud rip + import |
| 6 | Switch | 📋 Planned | not built as a dedicated feature |
| 7 | Misplaced Tracks | 🚧 Partial | continuous FSEvents watcher not built; "Library Consolidation" + `LibraryFolderSyncService` cover the "keep everything in one folder" goal |
| 8 | iTunes Migration | 📋 Planned | not started |
| 9 | Backup | ✅ Done | "Backup" tab (`LibraryBackupView`/`LibraryBackupService`); snapshot + restore |
| 10 | Tags & Cues | ✅ Tags / 🚧 Cues | "Tags" bulk editor + online metadata (iTunes/MusicBrainz/Discogs) + cover art; Serato cues/beatgrids are **preserved** on edit, but there's no dedicated cue-point editor yet |
| 11 | Sync (Rekordbox + cross-platform transfer) | 📋 Planned | not started; target transfer of tracks, cues, and crates between Serato and Rekordbox with safe export/import workflows |

### Shipped beyond the original spec

- ✅ **Download Audio** — YouTube/SoundCloud rip via yt-dlp (`YouTubeRipView`, `YouTubeAudioImportService`)
- ✅ **Library Consolidation** — flatten the whole library into one central folder
- ✅ **Buy-first purchase links** — confirmed iTunes + Beatport listings in PlaylistMatch (`PurchaseLinkService`)
- ✅ **Online metadata lookup** — iTunes/MusicBrainz/Discogs with cover-art embedding, DJ-descriptor-preserving titles
- ✅ **In-app audio player** with full transport controls
- ✅ **Serato play-count reader**
- ✅ **Auto-update checker + one-click installer** (`UpdateCheckService`)
- ✅ **Homebrew-managed runtime deps** + launch readiness banner (`RuntimeDependencyService`)
- ✅ **Finder Quick Action** ("Add to EZLibrary")

### MVP: Phase 1 (CrateView + Missing Tracks) — ✅ shipped

The original MVP is done. Rationale it proved out: it kept risk to reversible metadata changes (crate delete → Trash, path rewrite only — no audio files touched), delivered something every Serato user immediately wants, and needed zero external APIs or Xcode/extension work — buildable entirely with `swift build`.

