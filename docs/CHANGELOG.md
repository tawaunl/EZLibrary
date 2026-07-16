# Changelog

Notable changes per release. The version headings match the packaged build
version (`CFBundleShortVersionString.CFBundleVersion`) and are used verbatim by
`Scripts/release.sh` to populate the GitHub release notes.

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
