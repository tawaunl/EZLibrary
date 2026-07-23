# Changelog

Notable changes per release. The version headings match the packaged build
version (`CFBundleShortVersionString.CFBundleVersion`) and are used verbatim by
`Scripts/release.sh` to populate the GitHub release notes.

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
