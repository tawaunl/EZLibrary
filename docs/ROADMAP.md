# EZLibrary Feature Roadmap

## Status at a glance (updated 2026-07-18)

Legend: ✅ Done (shipped) · 🚧 In progress / partial · 📋 Planned · ⏸️ Tabled

The app has grown well past the original MVP. Phase 0 (binary read/write foundation) and most of the originally-planned features are shipped, plus a number of features that weren't in the original 11.

### Original 11 features

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
| 11 | Sync (Rekordbox) | 📋 Planned | not started |

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

### Foundation

- ✅ **Phase 0 complete** — `Format/`, `Parsers/`, `Writers/`, `Safety/`, `FileOps/`, `Watching/` all built and validated against a real 1343-track library (byte-exact path-rewrite round-trip).

### In progress

- 🚧 **ID3 title descriptor preservation** — keep DJ markers like "(Intro)"/"(Clean)" when applying an online title match (branch `feature/id3-title-descriptors`, PR #16).

### Planned / not started

- 📋 Feature 6 **Switch**, Feature 8 **iTunes Migration**, Feature 11 **Rekordbox Sync**
- 📋 Feature 7 continuous **Misplaced-Tracks watcher** (FSEvents `DirectoryWatcher`)
- 📋 Dedicated **cue-point editor** (Feature 10 cues)

### Tabled

- ⏸️ **Record Pool Search** (BPM Supreme / DJcity) — see "Tabled / future exploration" at the bottom.

---

## Context (original plan)

The skeleton macOS SwiftUI app (`EZLibraryCore` + `EZLibraryApp`) is in place and launches successfully. The user wants to build out 11 features (Add New Music, Missing Tracks, CrateView, Find Duplicates, CrateMatch, Switch, Misplaced Tracks, iTunes Migration, Backup, Tags & Cues, Sync/Rekordbox). Building all 11 at once isn't practical — they share a lot of core infrastructure (reading/writing Serato's binary library files) but vary hugely in risk (some are pure local file work, others require reverse-engineering third-party formats or external APIs). This plan lays out shared architecture, a phase order, and an MVP recommendation so we build the risky, load-bearing pieces once, early, and defer the most speculative work (audio fingerprinting, Rekordbox export, Spotify/iTunes integration) until the core is proven.

Decisions already confirmed with the user: macOS-only (the Windows mention in Feature 1's spec is leftover boilerplate, ignored), native Swift/SwiftUI, and the user delegated MVP/phase selection to us.

Project rule reference: see `docs/ENGINEERING_RULES.md` for code standards that apply across all phases, including the requirement that new user-facing errors must be human-readable.

**Note on research method**: to validate the plan's format assumptions, I had an agent inspect the real (if mostly empty) `~/Music/_Serato_/` files already on this machine — `database V2` and `Subcrates/*.crate` — read-only, to confirm the binary layout before we design around it. Findings below (UTF-16BE strings, the real nesting delimiter) came from that inspection.

## Two corrections to the original feature spec

1. **String encoding**: `database V2` fields are length-prefixed **UTF-16BE**, not ASCII/UTF-8. The parser/writer must decode/encode accordingly.
2. **Subcrate nesting delimiter**: real Serato files use the Unicode glyph **`≫≫`** (U+226B doubled) to separate parent/child crate names in a filename, not the ASCII `%%` mentioned in the brief. Hierarchy building must split on `≫≫`.

Only the file header/envelope was validated on this machine (the local library is empty of tracks) — before trusting the writer against a real user's data, we need a populated library or fixture to validate the full record schema (`otrk`/`pfil`/`tsng`/`tart`/`tbpm`/`tkey`, plus crate track-membership tags).

> **Update (Phase 0 complete):** all of the above has since been validated against a real, populated 1343-track library (see `Tests/EZLibraryCoreTests/Fixtures/RealLibrarySample/`), including a byte-exact path-rewrite round-trip. See git history for `Sources/EZLibraryCore/Format/`, `Parsers/`, `Writers/`, and `Safety/`.

## Shared core architecture (built once, reused across features)

> **Status: ✅ built.** Every module below now exists under `EZLibraryCore` and is validated against a real library. Kept here as the design reference.

All in `EZLibraryCore`:

- **`Format/` (new)** — `SeratoChunk`/reader/writer: a generic tag(4 ASCII bytes)+length(4-byte big-endian)+payload primitive shared by both `database V2` and `.crate` files, since they're the same envelope with different schemas. Every other format piece builds on this instead of re-parsing bytes independently.
- **`SeratoDatabaseParser` + new `SeratoDatabaseWriter`** — replaces the current stub in `Sources/EZLibraryCore/Parsers/SeratoDatabaseParser.swift`. Writer must round-trip byte-compatibly; this is the single highest-risk piece in the whole roadmap since a bug corrupts a real user's library.
- **`SeratoCrateParser` + `SeratoCrateWriter` (new)** — reads/writes individual `.crate` files (track membership + `ovct` column-view metadata).
- **`CrateHierarchy` (new)** — builds the parent/child tree from `Subcrates/` filenames split on `≫≫`.
- **`Safety/` (new)** — `SeratoProcessGuard` (refuse/warn on writes while Serato.app is running), `SeratoBackupBeforeWrite` (timestamped shadow copy before any mutation — the precursor to the user-facing Backup feature, not a duplicate of it), `AtomicFileWriter` (temp-file-then-rename so a crash never truncates a live file).
- **`FileOps/` (new)** — `TrackFileMover` (copy/move + verification), `SeratoPathRewriter` (the single choke point for rewriting `pfil` path references — every feature that moves files funnels through this one implementation).
- **`Watching/` (new)** — `FileSystemScanner` (one-shot indexed disk scan, needed for "fast even on large libraries") and `DirectoryWatcher` (FSEvents-based continuous watch, needed for Misplaced Tracks).
- **`Licensing/` (new, minimal stub now)** — a `FeatureFlag` seam so Find Duplicates' Pro-gated auto-replace has somewhere to hook in later without retrofitting.

## Phase order

> **Actual progress (development didn't strictly follow this order):** Phase 0 ✅ · Phase 1 ✅ (CrateView, Missing Tracks) · Phase 2 ✅ Add Music / 🚧 Switch & Misplaced Tracks partial · Phase 3 ✅ (Find Duplicates) · Phase 4 ✅ (Backup) · Phase 5 ✅ Tags / 🚧 Cues · Phase 6 ✅ (CrateMatch → PlaylistMatch) · Phase 7 📋 (iTunes Migration) · Phase 8 📋 (Rekordbox Sync). The table below is the original plan.

| Phase | Features | New core introduced | Why here |
|---|---|---|---|
| 0 | none (foundation) | Format/, Safety/ | Highest-risk, most load-bearing code; must be right before anything writes to a real library |
| 1 (**MVP**) | 3 CrateView, 2 Missing Tracks | CrateHierarchy, FileSystemScanner, SeratoPathRewriter | Read/metadata-only — no audio file ever moved/deleted — so bugs are low-blast-radius and backed by Phase 0's auto-backup. Immediately useful to any Serato DJ. No third-party formats, no extensions, works entirely with plain `swift build` today. |
| 2 | 1 Add New Music, 6 Switch, 7 Misplaced Tracks | TrackFileMover, DirectoryWatcher | First phase that moves actual audio files; deliberately after path-rewrite plumbing is proven on metadata-only Phase 1. Feature 1 needs a Finder Sync Extension decision here (see Risks) — plain SwiftPM can't build `.appex` targets, so this is where we likely need full Xcode. |
| 3 | 4 Find Duplicates | Fingerprinting/ engine, real use of Licensing/ | Audio fingerprinting is a new, isolated domain (Chromaprint via C-interop vs custom FFT) — worth spiking early once file-move plumbing exists, but isolated enough not to block anything else. |
| 4 | 9 Backup | Snapshot/restore atop Safety/'s copy primitives | Placed after real mutation history exists (Phases 1-3) so there's something worth protecting, before riskier external-integration phases begin. |
| 5 | 10 Tags & Cues | ID3 read/write, cue-point tag format (new reverse-engineering pass), offline suggestion DB | MP3-only scope keeps this contained. |
| 6 | 5 CrateMatch | Spotify ingestion, fuzzy metadata matching | Reuses matching concepts from Phase 3; needs Spotify API credentials decision. |
| 7 | 8 iTunes Migration | Library.xml (or MediaLibrary framework) reader | One-time-per-user tool, isolated risk, doesn't block others — reuses TrackFileMover/SeratoCrateWriter, no new file-move primitives. |
| 8 | 11 Sync (Rekordbox) | Rekordbox DB writer, cue→hot-cue conversion, USB export | Highest reverse-engineering risk in the roadmap; pure read-only export from our side (never writes back to Serato), so it can slip without blocking anything. Target the unencrypted `.PDB`/USB-export format first (also what CDJs actually read), not the SQLCipher-encrypted `master.db` — safer and may fully satisfy the "mirror to USB" requirement on its own. |

## Key open risks per feature (decide when that phase starts, not now)

- **Feature 1** ✅ resolved: shipped a **Finder Quick Action** ("Add to EZLibrary") instead of a Finder Sync Extension — no `.appex`/Xcode project needed.
- **Feature 4** ✅ resolved: fingerprinting uses **`fpcalc` (Chromaprint)** via `AudioFingerprintService` (Homebrew-managed), not a custom FFT.
- **Feature 5** ✅ resolved differently: Spotify's anonymous token/API is blocked, so PlaylistMatch reads the **embed page `__NEXT_DATA__`** JSON (Apple Music + CSV supported too).
- **Feature 8** 📋 open: `Library.xml` (needs user to enable "Share Library XML" in Music.app) recommended over Apple's semi-private `MediaLibrary` framework.
- **Feature 10** 🚧 partial: ID3 read/write is done in pure Swift (Serato cues/beatgrids preserved); a dedicated **cue-point tag editor** still needs its own format research pass.
- **Feature 11** 📋 open: target Rekordbox's unencrypted `.PDB` format, not encrypted `master.db` (legally/technically riskier, breaks on Pioneer updates).
- **Cross-cutting** ✅ resolved: tests run via the `runTests` tooling / Xcode; correctness validated against the real-library fixture in `Tests/EZLibraryCoreTests/Fixtures/`.

## MVP: Phase 0 + Phase 1 (CrateView + Missing Tracks) — ✅ shipped

The original MVP is done. Rationale it proved out: the highest-leverage core (binary read/write layer) shipped while keeping risk to reversible metadata changes (crate delete → Trash, path rewrite only — no audio files touched), delivered something every Serato user immediately wants, and needed zero external APIs or Xcode/extension work — buildable entirely with `swift build`.

## Next steps (forward-looking)

Foundation and MVP are complete; the app now ships 10 sidebar features (Tracks, Duplicates, PlaylistMatch, Add Music, Download Audio, Crates, Tags, Missing Tracks, Backup, Library Consolidation). Candidate next work, roughly in priority order:

1. **Finish in-progress:** land the ID3 title-descriptor-preservation change (PR #16).
2. **Feature 7 — Misplaced Tracks (full):** add the FSEvents `DirectoryWatcher` for continuous detection, building on the shipped Consolidation/`LibraryFolderSyncService`.
3. **Feature 10 — Cue-point editor:** cues are preserved today; a dedicated editor is the remaining gap.
4. **Feature 8 — iTunes Migration:** `Library.xml` reader → crates (isolated, one-time-per-user tool).
5. **Feature 6 — Switch** and **Feature 11 — Rekordbox Sync:** highest reverse-engineering risk; schedule last.
6. **Revisit tabled Record Pool Search** if a more reliable pool search surfaces (see below).

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

