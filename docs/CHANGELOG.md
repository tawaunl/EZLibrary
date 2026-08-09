# Changelog

Notable changes per release. The version headings match the packaged build
version (`CFBundleShortVersionString.CFBundleVersion`) and are used verbatim by
`Scripts/release.sh` to populate the GitHub release notes.

> **Maintenance commitment.** EZLibrary is actively maintained, with new releases
> roughly monthly (more often for fixes). Data-integrity and security issues are
> the highest priority — see [SECURITY.md](../SECURITY.md). This changelog is kept
> up to date so you can see exactly what changed and when.

## Unreleased

### Performance
- The trim editor's waveform no longer re-slices the whole envelope on every
  redraw. During playback at a fixed zoom the visible columns don't change, so
  the result is memoized — 2.2ms of work per second of playback drops to 0.1ms
  on a 6-minute track.
- Moving the mouse across the waveform no longer forces a full redraw. The
  pointer position (used only to anchor pinch-zoom) was stored in `@State`,
  which invalidated the view — and re-sliced the envelope — on every pointer
  event.
- Slicing the envelope no longer copies it first, removing a ~500KB allocation
  per redraw when zoomed out over a long track. (Neutral on wall-clock; the
  `max()` scan dominates.)
- The playhead timers in the trim editor and the mini player were built inline
  in `.onReceive`, which creates a new publisher and tears down the old
  subscription on every body evaluation — around 20 timers a second during
  playback. Both are now held across renders.
- Benchmarks for the waveform paths were added to `EZLibraryBench`; pass
  `EZBENCH_AUDIO=/path/to/track.mp3` to also time a real decode.

### YouTube downloads no longer tag the channel as the artist
- Downloads took the **channel name** as both the artist and the album, and the
  raw video title as the title. A video titled "E-40 & Too $hort - Dump Truck
  ft. …" uploaded by "E40TV" was tagged artist `E40TV`, album `E40TV`, title
  "E-40 & Too $hort - Dump Truck ft. …".
- With auto-rename from metadata switched on, those wrong values were then baked
  into the **file name** — and stayed there, because bulk tag operations (Fill
  Missing Genre/Year, Apply Top Hit) deliberately never rename. So correcting
  the tags later left the file name stuck on the channel name.
- The artist and title are now read out of the video title, which is where they
  actually live, and the channel's format decoration (`(Official Video)`,
  `[HD]`, `(Lyrics)`, …) is dropped. DJ-meaningful annotations —
  `(Dirty)`, `(Clean)`, `(Intro)`, `(Extended Mix)`, `(feat. …)` — are kept.
- When the title has no `Artist - Title` split, the artist is left **empty**
  rather than guessed. An empty field is easy to fill from a lookup; a wrong one
  silently corrupts the tag and the file name.
- Album is no longer seeded from the channel at all — the channel is never an
  album. It stays empty for a metadata lookup to fill.
- Existing files keep their old names. **Rename Files From Tags** in Tracks &
  Tags re-derives them from the corrected tags.

### Audio trim editor
- New **Edit Audio…** button in the Tracks & Tags bar opens a waveform editor
  for the selected track. Drag the in/out handles, type-check the times, and
  preview only the part you're keeping before committing.
- **Detect Silence** snaps the selection just inside the leading and trailing
  silence, so cutting dead air off a rip is one click.
- **Zoom** for precise cuts: the `+`/`−` buttons and keys, a pinch gesture over
  the waveform, **Fit**, and **Zoom to Selection**, with a scrubber for moving
  through the track while zoomed. The waveform is sampled at 400 points per
  second, so zooming reveals real detail instead of stretching the same columns.
- **Transport controls**: play/pause, skip back and forward 5 seconds, and jump
  to the start or end of the track, plus a fast-forward button cycling
  1× → 1.5× → 2× → 4× that scans at real speed rather than skipping.
- **Jumps and markers**: one-click jumps to the in and out points, and a
  droppable marker (`M`) you can return to (`⇧M`) while hunting for a cut —
  distinct from the playhead and drawn separately on the waveform.
- Playing from inside the selection stops at the out point, so you hear exactly
  what you'd keep. Playing from past it runs to the end of the file instead, so
  the tail you're about to cut can be auditioned before you commit to losing it.
- **Keyboard playhead control**: `←`/`→` step by 0.1s (`⇧` for 1s, `⌥` for
  0.01s), `⌘←`/`⌘→` jump to the in/out points, `Home`/`End` to the track
  boundaries, and `Space` plays or pauses. The view follows the playhead
  automatically when zoomed in.
- **Set In Here** / **Set Out Here** (or `I` / `O`) make the marker's position
  the new trim point — so you can nudge to the exact spot, set the in point
  there, and play straight from the new start.
- Two ways to save: **Save In Place** overwrites the file (keeping a timestamped
  backup of the original in EZLibrary's pre-write backup folder), and **Save As
  New File** writes a second copy, registers it in `database V2`, and files it
  next to the original in every plain crate that holds it.
- The cut is a stream copy — no re-encode, so audio quality is untouched and
  text tags plus embedded cover art survive.
- Trimming shifts the whole timeline, which invalidates Serato's cue points,
  saved loops, beatgrid and waveform overview. Those are cleared so Serato
  re-analyzes the track cleanly rather than showing cues in the wrong places;
  the editor reads the file first and tells you exactly how many cues and loops
  you'd lose before you save.
- Both save paths refuse while Serato is running, since Serato rewrites its
  library from memory on quit and would undo the change.

## 1.0.0

### Renaming a file no longer loses it in Serato
- Renaming a track from its tags used to orphan it: Serato showed the renamed
  file as a brand-new track and the original as **"cannot be located"**, losing
  the cue points, beat grid and play count attached to it.
- A rename now updates **everything Serato reads** in one operation — its SQLite
  library, `database V2`, plain crates, and smart crates — so the track keeps
  its identity, its cues, and its crate membership.
- Smart crates were the last piece: a `.scrate` keeps a materialized list of
  member paths beside its rules, and a stale path there was enough for Serato to
  re-import the old name as a second, missing entry.
- Renames now refuse and roll back rather than half-apply. If the track can't be
  matched in Serato's library, the file is put back under its original name.

### Bulk rename
- New **Rename Files From Tags** button in the Tracks & Tags bulk bar: renames
  every selected file using your filename format, and updates Serato to match.
- A resizable preview lists every rename before anything happens, with a plain
  summary of what's being skipped and why.
- Anything ambiguous is skipped rather than guessed — tracks already named
  correctly, names that would collide with another selected track, destinations
  already taken, and tracks not in the Serato library.
- Renames the whole selection in a single pass over each file, so a large
  selection stays fast.

### Filename format
- The filename template in Settings now actually drives renaming. It previously
  only fed the settings preview while renames used a fixed
  `artist-title-album-year-genre` pattern.
- Tokens that have no value are dropped along with their separators, so a
  missing album or year can't leave a stray dash in the name.

### Library index repair
- New `EZLibraryCLI repair-locations` command re-points Serato's library at
  where files actually are, for libraries knocked out of sync by an earlier
  move or consolidation. Previews by default; `--apply` writes.
- Matches on filename and file size, repairs rows in place so cues and crate
  membership survive, and reports anything it can't resolve instead of guessing.

### Fixes
- Re-saving a track without changing anything no longer walks its filename to
  `name (2)`, then `name (3)` — the file was being treated as a collision with
  itself.
- Tag-write verification now runs before the library is written. It previously
  ran after, so a failed verification rolled the file rename back while leaving
  the new path committed — exactly the state where Serato can't find the track.

## 0.1.0.9

### Audio-verified duplicate detection
- Added **offline audio fingerprint matching** so duplicate detection can verify
  tracks by audio content, even when metadata is inconsistent.
- Added whole-library audio scan support and surfaced audio verification details
  directly in the Duplicates tab.
- Fingerprint and verification results are now cached for faster repeat scans.

### Safer duplicate cleanup
- Duplicate groups now keep DJ version markers separate (for example Intro,
  Extended, Clean, Dirty, Remix, and Edit variants) to reduce false merges.
- Duplicate deletion was hardened to avoid half-applied states and keep crates
  reconciled when removing redundant entries.
- Added better retention controls, including Pick Best/Keep workflows and
  preserving results visibility after deletion actions.

### Performance and stability
- Improved crate and parser performance by reducing allocations and enabling
  parallel processing for heavy library operations.
- Updated tests and shared-state handling to improve reliability with parallel
  test execution.

## 0.1.0.8

### Built for big libraries
- **Much faster launch and loading.** Opening EZLibrary and reading your Serato
  library is dramatically quicker, and the window no longer freezes while it
  loads — libraries with tens of thousands of tracks now open in a fraction of
  the time.
- **No more freezes while you work.** Editing tags, deleting tracks, importing,
  and switching between sections no longer lock up the interface on large
  libraries; the heavy work runs in the background and the list updates when
  it's ready.
- **Instant search and filtering.** Searching and filtering tracks is far
  faster, even across very large libraries.
- **Smoother scrolling** through long track lists.

### Fixes
- Bulk tag edits now reliably refresh the track list right away.
- Startup update and dependency checks are deferred a moment so they don't
  compete with loading your library when the app first opens.

## 0.1.0.7

### Tracks & Tags are now one section
- The separate **Tracks** and **Tags** views are combined into a single
  **Tracks & Tags** section with all of both features: browse the whole
  library, pick a crate scope, bulk-fill artist/album/genre/year, look up
  metadata online, and delete tracks — all in one place.
- **Click a completion stat to filter.** Clicking *Artist/Album/Genre/Year
  Filled* filters the table to just the tracks missing that field (e.g. 80%
  filled shows the other 20%). Click again, or the **Tracks** box, to clear.
  A field that's 100% filled applies no filter.

### PlaylistMatch: buy, import, and download
- Confirmed **purchase links** for matched and planned tracks from the iTunes
  Store and Beatport, grouped by store with per-version options.
- **"I bought it" import** brings a purchased file into the library, and a
  Downloads-folder watcher auto-detects finished downloads and offers to import
  and file them into your central music folder.
- **Download fallback** for YouTube and SoundCloud, with in-app suggestions that
  skip music videos.
- Remix/version titles now match their library originals, and personalized
  Spotify mixes are flagged with guidance for an exact match.

### Copy any text
- **All text throughout the app is now selectable**, so you can highlight and
  copy values from ID3 lookups, playlist searches, and everywhere else.

### Backups fixed
- **Incremental backups now correctly skip** tracks already captured in the
  previous backup instead of re-copying everything.
- **Single-crate backups no longer abort** when a crate references a file that
  has been moved or deleted — missing files are skipped.

### Other
- "YouTube Rip" is now **Download Audio**, and supports SoundCloud as well.
- Added a reusable folder picker with recent-folder history across views.

## 0.1.0.6

### Renamed to EZLibrary
- The app is now called **EZLibrary**. Your existing settings, saved library
  location, API keys, and Finder Quick Actions keep working unchanged.
- Added a clear notice that EZLibrary is an independent tool and is **not
  affiliated with or endorsed by Serato**.
- Configuration environment variables were renamed from `SERATOTOOLS_*` to
  `EZLIBRARY_*`. The old names are still honored as a fallback, so existing
  Finder Quick Actions continue to work without reinstalling.

## 0.1.0.5

### Dependencies now managed by Homebrew
- EZLibrary no longer bundles `ffmpeg`/`ffprobe` or `fpcalc`.
  These command-line tools are now installed and kept up to date through
  Homebrew, so they never go stale as the audio tools change.
- **Every launch checks that the tools are installed and current.** When
  something is missing or an update is available, a banner appears at the top
  of the window with a one-click **Install / Update** button.

## 0.1.0.4

### Tags
- The bulk **Tags** view gained **genre filter buttons**, matching the Tracks
  view, so you can narrow the scope by genre while editing.
- The **audio player now works in the Tags view** — activate a track to play it
  with the shared transport controls.

### Safer tag editing
- **Auto-rename from metadata is now off by default.** Renaming files that
  Serato had already analyzed orphaned the original library entry and made
  Serato re-import the file as a new track. Tag edits now update metadata in
  place. A one-time migration turns the setting off for existing installs; it
  can be re-enabled in Settings → Automation.
- Tag edits now **refuse to run while Serato is open**, preventing Serato from
  overwriting the changes (and orphaning renamed files) when it quits.
- Editing crate tracks no longer leaves them showing as **"Not in local
  library"** — crates are reloaded after edits that can rewrite their paths.

### Cue points
- Serato **cue points and beatgrids are now preserved** when editing ID3 tags.
  The tag writer previously dropped Serato's embedded data on files using
  tag-level unsynchronisation or v2.4 frame flags.

## 0.1.0.3

### Track player
- The play control now toggles between a **play** and **pause** icon so it
  always reflects whether the track is currently playing.
- **Spacebar** now pauses and resumes at the current position instead of
  stopping and restarting the track from the beginning.
- The mini player gained full **transport controls**: previous / next track,
  play / pause, and skip back / forward 15 seconds.
- **Next / previous** follow the order of the list you are viewing, respecting
  the active search filter and column sort.

## 0.1.0.2

- App icon (gold glow) bundled into the release.
- Batch metadata updates and caching for online lookups.

## 0.1.0.1

- Initial standalone installer release.
