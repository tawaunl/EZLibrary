# Changelog

Notable changes per release. The version headings match the packaged build
version (`CFBundleShortVersionString.CFBundleVersion`) and are used verbatim by
`Scripts/release.sh` to populate the GitHub release notes.

> **Maintenance commitment.** EZLibrary is actively maintained, with new releases
> roughly monthly (more often for fixes). Data-integrity and security issues are
> the highest priority — see [SECURITY.md](../SECURITY.md). This changelog is kept
> up to date so you can see exactly what changed and when.

## 1.0.7

### Resizable and collapsible side panels
- The Crates list next to the track list — and the crate/scope panel in Tracks &amp; Tags —
  can now be dragged wider or narrower, so you can hand more room to the track columns on a
  smaller screen or give the crate tree more space when you need it.
- Each panel collapses to a slim icon strip with a single click, and clicking that icon (or
  the arrow) brings it right back. The main sidebar collapses the same way, shrinking to
  icon-only navigation. Panel widths and collapsed state are remembered between launches.

## 1.0.6

### Downloaded audio no longer stores the source link in the comment tag
- Ripping a track from YouTube, SoundCloud or any other source used to stamp the
  original web link into the ID3 comment. That link now stays blank, so imported
  tracks land in your library with a clean comment field ready for your own cue notes.

## 1.0.5

### Automatic cleanup of stale library locations
- Over time Serato's library collects "disconnected" locations — an old drive, a previous
  library layout, or a streaming service you no longer use — that it keeps listing but can
  never actually play. EZLibrary now clears these out automatically after a bulk move,
  rename or consolidation, so reorganizing your files no longer leaves "cannot be located"
  clutter behind.
- Only locations that are provably dead are removed: an all-streaming leftover, one whose
  files are all missing, or one whose only remaining files are duplicates already in your
  live library. A location that still holds files of its own — including a drive that is
  simply unplugged — is always left alone, the cleanup only runs while Serato is closed, and
  every removal is backed up first.

### DJ Pool Records added as a metadata source
- Tag verification and online lookup can now cross-check **DJ Pool Records**, which knows
  the DJ-edit versions the regular catalogs don't. For an edit-heavy library it helps
  confirm the exact artist, edit title and BPM of tracks that iTunes, Deezer and the others
  only know in their original form.
- It contributes artist, title and BPM only — no album or year — and never outweighs the
  main catalog sources, so it fills gaps without changing tags the catalogs already agree on.

## 1.0.4

### Fixed: the automatic update could not quit the app to install
- "Install &amp; Relaunch" downloaded the update, but the app did not reliably close,
  so the bundled installer could not replace the running copy and the update appeared
  to do nothing. The update sheet was blocking the app's own request to quit.
- The app now dismisses the sheet and force-quits when a normal quit is blocked, so the
  installer can complete and the app reopens on the new version.
- Because this fixes the updater itself, a copy already on 1.0.3 or earlier has to be
  updated by hand once — download the latest installer from the
  [Releases page](https://github.com/tawaunl/EZLibrary/releases/latest). Automatic updates
  work from 1.0.4 onward.

### Tag searches keep running when you leave Tracks &amp; Tags
- A bulk tag verification or "fill missing tags" job used to stop the moment you clicked
  away to another section. These jobs now run in the background and keep going while you
  browse crates, download tracks or play music, with a banner showing progress and a Stop
  button from anywhere in the app.
- The tracks a job is working on are locked while it runs. Editing, deleting, renaming,
  re-reading or bulk-filling those tracks is refused with a clear message until the job
  finishes — so a background write and a manual edit can never fight over the same file.
  Everything else in your library stays fully editable.

### Verification fills in more missing fields
- When a field is blank, both the on-device and cloud engines now propose a value whenever
  any source has one, instead of leaving it unverified. Completing empty tags is treated as
  the top priority, while fields you already have are still only changed when the evidence is
  strong.

## 1.0.3

### Wikipedia added as a metadata source
- Tag verification and online lookup now cross-check **Wikipedia** alongside iTunes,
  MusicBrainz, Deezer and Discogs.
- Wikipedia is the most reliable source for the *original* album a song first appeared
  on — the catalog APIs routinely return the single or a later hits compilation instead.
  The cross-source consensus now gives Wikipedia the final say on the album, so a track's
  album is set to the record it actually came from rather than the single it was sold on.
- Filling an empty album from Wikipedia is trusted enough to apply unattended; *overwriting*
  an album you already have stays below the auto-apply line, so a questionable rewrite is
  shown for review instead of written silently.

### The on-device AI is more accurate
- Apple's on-device model is now handed the database results directly instead of being
  trusted to search for them, the same way the cloud model works. The app does the
  searching; the model does the judging, which is what a small on-device model is actually
  good at.
- It now also consults MusicBrainz and Discogs, searches from the file's own ID3 tags
  rather than the file name, and follows the same field rules as the cloud model.

### The year is filled from the file name
- When a track's year is missing from its ID3 tag but present in the file name (for example
  `Artist - Title (2019)`) or in Serato's library, verification now fills it in instead of
  leaving it blank.
- A database release year still wins whenever one is found; the file-name year is only a
  fallback, offered for review rather than written silently.

### The artist is kept out of the title
- Whatever engine proposes a title, a leading or trailing artist name ("Justice - D.A.N.C.E.",
  "Sail - AWOLNATION") is stripped so only the song name lands in the title field. DJ version
  markers like (Extended Mix) and (Clean) are still preserved.

### See the current tags while you review
- The verification review now shows all five current tag values — title, artist, album,
  genre and year — for each track above the proposed changes, so you can see the whole
  state being judged, not only the fields a source wants to change.

### YouTube as an optional genre fallback
- You can add your own YouTube Data API key in Settings to let verification infer a genre
  from a video's title and description when the free sources come up empty. It is off unless
  you add a key, spends only your own quota, and never runs on the default free path.

## 1.0.2

### Writes are blocked while Serato is open
- EZLibrary now treats the library as read-only for as long as Serato is running.
  Serato rewrites its library and crates from memory on quit, so edits made
  underneath it can be silently reverted.
- The guard now covers the remaining write paths that were still exposed,
  including **Add Music**, folder sync, and the new tag refresh workflow.
- The app shows a banner while Serato is open and disables the bulk tag,
  crate-edit, and Add Music controls as groups, so later actions are covered by
  default too.

### Refresh library tags from the audio files
- New **Re-read Tags From Files** action in Tracks & Tags re-reads each selected
  track's embedded audio tags and writes the current values back into Serato's
  library.
- This is the repair path for tracks whose file tags were fixed elsewhere and
  now disagree with `database V2`.
- The refresh runs through the same verified write path as other metadata edits,
  so failures still roll back cleanly instead of half-applying.

### Folder sync can rename from tags and keep crates pointed at the file
- Folder sync can now rename imported tracks from their audio metadata instead
  of leaving them on the source filename.
- When sync renames a file, EZLibrary now rewrites every plain and smart crate
  entry that still points at the old stored path, so the track does not drop out
  of crates or reappear as a second missing entry in Serato.
- A rename also repoints the track's row in Serato's own `location.sqlite`,
  keeping the asset id so the track's cues and crate membership stay attached.
  Without it Serato re-imports the renamed file as a brand-new track — its log
  says "Adding track not found in database" — and leaves the original row
  pointing at a path that no longer exists.
- A file Serato has never seen has no row to repoint, which is the normal case
  for a folder sync and is not reported as a problem. A rename blocked by a
  different track already claiming that path is reported instead.
- Sync results were expanded to report the rename work alongside the normal file
  transfer updates.

### Better metadata handling and error messages
- Audio tag reads used by sync were tightened up so imported metadata is more
  complete and database updates stay in step with the file on disk.
- Crate-editor and parser failures now surface plain-language recovery messages
  instead of raw Swift error names, including the case where quitting Serato is
  the fix.

## 1.0.1

### Fixed: Search Online stopped returning matches
- A lookup that came back empty — a brief network drop, an online source
  rate limiting us, or closing the sheet mid-search — was written into the
  lookup cache, so **Search Online** kept answering "No matches found" from
  memory for the next five minutes. Pressing it again appeared to do nothing.
  Only complete results are cached now, so a retry actually retries.
- Requests to each online source are paced, and a source that starts rate
  limiting is retried with backoff instead of being reported as a track with
  no matches. iTunes answers a throttled search with an empty response that
  used to be indistinguishable from "nothing found".
- When every source fails, the reason is shown rather than "No matches found",
  which read as a track that isn't in the stores.
- The bulk tag actions now say how many tracks could not be looked up, instead
  of reporting only that nothing was filled in.

### Add and remove crate membership from a track's right-click menu
- Secondary-clicking a track now offers **Add … to Crate**, with a submenu of
  every crate, and — when a crate is on screen — **Remove … from "<crate>"**.
- Acts on the whole selection when the clicked row is part of it, otherwise on
  just the row under the pointer, the way Finder behaves.
- Adding skips tracks the crate already lists, and both operations re-read the
  crate from disk first, so a change made since the view loaded isn't undone.
- Smart crates are left out of the menu: their membership comes from rules, so
  a hand-added track would be discarded on the next re-evaluation.

### All Tracks and Not In Crates in the Crates view
- The crate list now starts with **All Tracks** and **Not In Crates**, selected
  the same way as a crate — the way All Tracks already works in Tracks & Tags.
  Both list tracks with the Tracks view's search and sorting, and the tree stays
  visible beside them, so songs can be dragged straight onto a crate.
- **Not In Crates** shows every track filed in no crate at all — the ones easy
  to forget and never play. It's also a clickable stat at the top of the
  section, next to Tracks In Crates, with a live count.
- Smart crates don't count as filing, since their membership is rule-derived
  rather than something you filed. That keeps the number consistent with the
  Tracks In Crates stat beside it.
- Crate membership is matched on normalised paths (separators, leading slash,
  case), so a track already filed isn't wrongly listed as unfiled.
- Dropping a track a crate already contains no longer files it twice. Serato
  reads a repeated path as a second copy, and dropping something already filed
  is the easiest mistake to make when dragging from a full-library list.

### Tag values are trimmed on save
- Every text field written to `database V2` and to a file's ID3 frames — title,
  artist, album, genre, comment, key — is now whitespace-trimmed.
- Stray padding is easy to pick up (a pasted artist name, a scraped video title,
  a hand-typed field) and close to invisible once written, while quietly
  breaking anything that compares or sorts on the value: `"Drake "` and
  `"Drake"` are two different artists to Serato, sort apart, and render
  different file names.
- Both ends are trimmed, not just the trailing side. A leading space does more
  visible damage — it sorts the track to the top of the list, away from the rest
  of that artist. Interior spacing is left alone.
- Trimming lives on `SeratoTrackMetadataUpdate`, the one type every writer goes
  through, so it applies whether the value came from a manual edit, an online
  lookup, a bulk fill, or a YouTube download.
- Existing files keep their current tags until something re-saves them, or
  until you run the cleanup action below.

### Clean Tag Whitespace
- New button in the Tracks & Tags bar. It scans the current scope (All Tracks,
  or whichever crate is selected) for tag values padded with leading or
  trailing spaces, and re-saves them trimmed.
- Nothing is written until you confirm. The prompt reports how many tracks are
  affected and which fields — e.g. "70 tracks have tag values padded with
  spaces: Artist (48), Title (23)" — with a few example file names.
- A field that is *only* whitespace is left alone: trimming it to empty would
  erase a value rather than tidy one.
- File names are not changed, only the tag values. Filenames were already
  trimmed by the renamer's own sanitising, so they never carried the padding.

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
