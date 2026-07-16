# Changelog

Notable changes per release. The version headings match the packaged build
version (`CFBundleShortVersionString.CFBundleVersion`) and are used verbatim by
`Scripts/release.sh` to populate the GitHub release notes.

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
