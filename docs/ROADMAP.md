# SeratoTools Feature Roadmap

## Context

The skeleton macOS SwiftUI app (`SeratoToolsCore` + `SeratoToolsApp`) is in place and launches successfully. The user wants to build out 11 features (Add New Music, Missing Tracks, CrateView, Find Duplicates, CrateMatch, Switch, Misplaced Tracks, iTunes Migration, Backup, Tags & Cues, Sync/Rekordbox). Building all 11 at once isn't practical — they share a lot of core infrastructure (reading/writing Serato's binary library files) but vary hugely in risk (some are pure local file work, others require reverse-engineering third-party formats or external APIs). This plan lays out shared architecture, a phase order, and an MVP recommendation so we build the risky, load-bearing pieces once, early, and defer the most speculative work (audio fingerprinting, Rekordbox export, Spotify/iTunes integration) until the core is proven.

Decisions already confirmed with the user: macOS-only (the Windows mention in Feature 1's spec is leftover boilerplate, ignored), native Swift/SwiftUI, and the user delegated MVP/phase selection to us.

Project rule reference: see `docs/ENGINEERING_RULES.md` for code standards that apply across all phases, including the requirement that new user-facing errors must be human-readable.

**Note on research method**: to validate the plan's format assumptions, I had an agent inspect the real (if mostly empty) `~/Music/_Serato_/` files already on this machine — `database V2` and `Subcrates/*.crate` — read-only, to confirm the binary layout before we design around it. Findings below (UTF-16BE strings, the real nesting delimiter) came from that inspection.

## Two corrections to the original feature spec

1. **String encoding**: `database V2` fields are length-prefixed **UTF-16BE**, not ASCII/UTF-8. The parser/writer must decode/encode accordingly.
2. **Subcrate nesting delimiter**: real Serato files use the Unicode glyph **`≫≫`** (U+226B doubled) to separate parent/child crate names in a filename, not the ASCII `%%` mentioned in the brief. Hierarchy building must split on `≫≫`.

Only the file header/envelope was validated on this machine (the local library is empty of tracks) — before trusting the writer against a real user's data, we need a populated library or fixture to validate the full record schema (`otrk`/`pfil`/`tsng`/`tart`/`tbpm`/`tkey`, plus crate track-membership tags).

> **Update (Phase 0 complete):** all of the above has since been validated against a real, populated 1343-track library (see `Tests/SeratoToolsCoreTests/Fixtures/RealLibrarySample/`), including a byte-exact path-rewrite round-trip. See git history for `Sources/SeratoToolsCore/Format/`, `Parsers/`, `Writers/`, and `Safety/`.

## Shared core architecture (built once, reused across features)

All in `SeratoToolsCore`:

- **`Format/` (new)** — `SeratoChunk`/reader/writer: a generic tag(4 ASCII bytes)+length(4-byte big-endian)+payload primitive shared by both `database V2` and `.crate` files, since they're the same envelope with different schemas. Every other format piece builds on this instead of re-parsing bytes independently.
- **`SeratoDatabaseParser` + new `SeratoDatabaseWriter`** — replaces the current stub in `Sources/SeratoToolsCore/Parsers/SeratoDatabaseParser.swift`. Writer must round-trip byte-compatibly; this is the single highest-risk piece in the whole roadmap since a bug corrupts a real user's library.
- **`SeratoCrateParser` + `SeratoCrateWriter` (new)** — reads/writes individual `.crate` files (track membership + `ovct` column-view metadata).
- **`CrateHierarchy` (new)** — builds the parent/child tree from `Subcrates/` filenames split on `≫≫`.
- **`Safety/` (new)** — `SeratoProcessGuard` (refuse/warn on writes while Serato.app is running), `SeratoBackupBeforeWrite` (timestamped shadow copy before any mutation — the precursor to the user-facing Backup feature, not a duplicate of it), `AtomicFileWriter` (temp-file-then-rename so a crash never truncates a live file).
- **`FileOps/` (new)** — `TrackFileMover` (copy/move + verification), `SeratoPathRewriter` (the single choke point for rewriting `pfil` path references — every feature that moves files funnels through this one implementation).
- **`Watching/` (new)** — `FileSystemScanner` (one-shot indexed disk scan, needed for "fast even on large libraries") and `DirectoryWatcher` (FSEvents-based continuous watch, needed for Misplaced Tracks).
- **`Licensing/` (new, minimal stub now)** — a `FeatureFlag` seam so Find Duplicates' Pro-gated auto-replace has somewhere to hook in later without retrofitting.

## Phase order

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

- **Feature 1**: Finder Sync Extension needs a real Xcode project (multi-target `.appex` + App Group entitlement) — not possible with plain SwiftPM. Fallback: ship v1 via a menu-bar helper or Quick Action instead of true Finder right-click, upgrade later.
- **Feature 4**: fingerprinting library choice (Chromaprint C-interop vs custom FFT/Accelerate) — spike this early in Phase 3 to de-risk linking before committing.
- **Feature 5**: Spotify official API (client-credentials, no user login needed for public playlists) recommended over scraping.
- **Feature 8**: `Library.xml` (needs user to enable "Share Library XML" in Music.app) recommended over Apple's semi-private `MediaLibrary` framework.
- **Feature 10**: prefer a pure-Swift ID3 library over C-interop (TagLib) since MP3-only v1 scope is narrow; cue-point tag schema needs its own format research pass.
- **Feature 11**: target Rekordbox's unencrypted `.PDB` format, not encrypted `master.db` (legally/technically riskier, breaks on Pioneer updates).
- **Cross-cutting**: `swift test`/swift-testing does not execute under Command-Line-Tools-only (confirmed this session) — write tests as we go but verify Phase 0/1 correctness via manual round-trip diffing until full Xcode is installed.

## MVP: Phase 0 + Phase 1 (CrateView + Missing Tracks)

Recommended starting point. Rationale: proves the highest-leverage core (binary read/write layer) while keeping risk to reversible metadata changes (crate delete → Trash, path rewrite only — no audio files touched), ships something every Serato user immediately wants, and needs zero external APIs, zero third-party format reverse-engineering, and zero Xcode/extension work — buildable entirely with today's `swift build` setup.

## Next steps after approval

1. Start Phase 0: implement `Format/SeratoChunk`, replace the `SeratoDatabaseParser` stub with a real UTF-16BE-aware reader, add `SeratoDatabaseWriter`, `SeratoCrateParser`/`Writer`, and the `Safety/` module (process guard, backup-before-write, atomic writer).
2. Acquire or synthesize a populated `_Serato_` fixture (real library copy or hand-built test data) to validate the full record schema beyond the empty-header case already inspected.
3. Only after Phase 0 is verified against that fixture, move into Phase 1 (CrateView UI + Missing Tracks scan/repair flow), extending `LibraryService` and `ContentView`.
