# Audio Fingerprint Duplicate Detection

Finds duplicates by what a track **sounds like**, so it catches copies that
metadata matching misses — different filenames, missing or wrong tags, and the
same recording in a different format or bitrate.

This augments the existing ID3/metadata matching in `DuplicateTracksService`;
it does not replace it.

## Why offline

`AudioFingerprintService` already shells out to `fpcalc` (Chromaprint), but it
sends the *compressed* fingerprint to AcoustID to get metadata suggestions back.
That path is wrong for duplicate detection at library scale: it needs an API
key, and AcoustID rate-limits to roughly 3 requests/second — a 50k library would
take hours and fail without a key.

`fpcalc -raw` instead emits the underlying 32-bit sub-fingerprints (one per
~0.1238s of audio). Those bits are directly comparable, so two files can be
matched **against each other** with no network call and no key.

## Matching

`AudioFingerprintMatcher` scores a pair by bit error rate over the best
alignment:

- Shift one fingerprint against the other by ±60 frames (~±7.4s) to absorb
  differing silent lead-ins.
- Score = `1 - (differing bits / compared bits)`.
- At or above **0.85**, the two are the same recording.

Clustering is single-linkage union-find, so a group becomes one card per
recording even when the weakest pair sits just under the threshold.

### Measured separation

Real audio, one track re-encoded several ways versus an unrelated track:

| Case | Score |
| --- | --- |
| Identical file | 1.0000 |
| 320k → 128k re-encode | 0.9921 |
| mp3 → m4a/AAC | 0.9905 |
| 2s silent lead-in prepended | 0.9761 |
| **Unrelated track** | **0.5265** |

Unrelated fingerprints sit near 0.5 because independent bits agree about half
the time. The 0.85 threshold therefore has a **0.45 margin** on both sides,
which is why the exact value is not delicate.

### Short audio is refused, not guessed

Below `minimumComparableFrames` (40 frames, ~5s) the matcher returns 0 rather
than a score. Very short fingerprints match by coincidence — five small
integers against five copies of `9` scores 0.93 purely because both are
mostly zero bits. Since this feature's output leads to deleting files,
refusing to judge is the correct answer.

## Attribution safety

`fpcalc` accepts many files per invocation, which is ~30% faster than one
process per file. But its output is bare `DURATION=`/`FINGERPRINT=` records
with **no filename**, and it **aborts the remaining files** as soon as one
fails to decode — three inputs with a corrupt file in the middle produce one
record, not three.

Attributing records positionally is therefore only safe when the record count
matches the input count exactly. `AudioFingerprintExtractor` takes the batched
fast path only on an exact match and otherwise falls back to one process per
file, where attribution cannot be ambiguous. A single corrupt file is reported
in `failures` and never shifts another track's fingerprint onto the wrong file.

## Scaling to 50k tracks

Measured on this machine (10 logical cores, `-length 120`):

| Mode | Throughput |
| --- | --- |
| One file per process | ~7 files/s |
| Batched, serial | ~11 files/s |
| Batched, 8-way parallel | **~56 files/s** |

A cold full-library scan of 50k tracks is therefore ~15 minutes — acceptable as
a one-time background job, but not something to repeat on every view load.
Two things keep it off the hot path:

**Gate before fingerprinting.** Extraction is the only expensive stage, so it
runs last and only on survivors:

1. Metadata candidate groups (existing, free).
2. Duration within tolerance — `Track.duration` is already parsed, free.
3. Fingerprint only what is left.
4. Pairwise compare within the group — microseconds, and O(group²), never
   O(library²).

In a 50k library only a small fraction of tracks are metadata candidates, which
brings a typical scan well under a minute.

**Cache.** Fingerprints are stable for a given file, so they should be stored
keyed by path + size + mtime and recomputed only when a file changes. A raw
120s fingerprint is 948 × 4 bytes ≈ 3.8 KB, so caching candidates costs a few
MB rather than the ~190 MB a whole 50k library would.

`-length` trades accuracy for speed roughly linearly (120s ≈ 0.14s/file, 60s ≈
0.09s, 30s ≈ 0.04s) and is the tuning knob if scans need to be faster.

## When the tags are wrong

Verifying metadata groups can only ever *narrow* what tag matching already
found. If two copies have different artists and titles, they never land in the
same metadata group, so nothing downstream compares them.

**Scan Whole Library** starts from the audio instead and ignores tags entirely.
Measured on a 600-file slice of a real library:

| Pass | Groups | Tracks involved |
| --- | --- | --- |
| ID3/metadata | 38 | 78 |
| Audio scan | **144** | **299** |

110 of those groups had disagreeing tags, so metadata matching could not have
found them. Real examples:

```
112 - Anywhere [lEWSkYM5aqA].mp3
112 ft Lil' Zane - Anywhere (Intro Dirty).mp3

Choppa Style ft. Master P 1-Choppa-Choppa Style - Single-2018.mp3
Choppa-Choppa Style-Choppa Style-2001.mp3
Chopper City-Choppa Style ft. Master P-...-2002.mp3
```

### Making it scale

A whole-library scan cannot compare every pair — 50k tracks is 1.25 billion
pairs at ~115k operations each. `AudioFingerprintIndex` narrows the field
first:

1. Each track gets a 64-value MinHash signature: its sub-fingerprints are run
   through a 32-bit finalizer and the 64 smallest kept. Values are chosen by
   rank, not position, so a trimmed or padded lead-in barely changes the
   signature.
2. Signatures go into an inverted index — a flat sorted `(value, track)` array
   rather than a dictionary of arrays, keeping 50k tracks near 25 MB.
3. Values held by more than 100 tracks are skipped. Digital silence says
   nothing about any pair and would otherwise generate enormous posting lists.
4. Pairs sharing ≥4 signature values get a full comparison.

Measured separation, versus a re-encoded copy of the same track:

| Pair | Shared of 64 |
| --- | --- |
| 320k → 128k re-encode | 48 |
| mp3 → m4a/AAC | 51 |
| 2s silent lead-in | 34 |
| Unrelated track | **0** |

On 400 real tracks this cut 79,800 possible pairs to 137 candidates — a 582x
reduction — with no true duplicate lost. Random collisions are negligible
(~64²/2³² per pair), so the candidates are almost entirely real.

The full-library decode is still the cost: ~15 minutes for 50k on the first
run. It is checkpointed every 500 files, so cancelling or quitting costs at
most that much rework, and a rescan off the cache was 11x faster on the
600-file slice.

Peak memory holds every fingerprint for the comparison stage — roughly 190 MB
at 50k tracks. Acceptable for a one-time scan, and the first thing to revisit
if libraries get much larger.

## How a scan reads

Verification is opt-in, from the **Verify by Audio** card in the Duplicates
tab. Metadata grouping still runs on its own and is unchanged; pressing
*Verify Groups* then re-derives the groups from the audio and badges each one:

| Badge | Meaning |
| --- | --- |
| Audio verified | Every track was fingerprinted; they are the same recording. |
| Audio verified (split) | Fingerprinting carved up a larger tag-matched group. |
| Audio match · tags differ | Same recording, disagreeing tags — only the whole-library scan finds these. |
| Tags only | Could not fingerprint every track — reported, never upgraded. |

Tracks the audio proves distinct are dropped from their group and counted in
the scan summary, so they are no longer offered for deletion.

### Listening before deleting

Every copy in a group has a play button, backed by the existing
`TrackAudioPlayerViewModel` rather than a second player. One player is shared
across the view, so starting a copy stops whatever was playing.

Switching between copies in the same group **keeps the playhead** — the whole
point of auditioning duplicates is hearing the same moment in both, not
restarting from the top each time. `audition(track:startingAt:)` exists for
that: unlike `load(track:)` it reloads even when the path is unchanged, which
`load` deliberately skips.

Playback stops before any delete, so the player isn't holding an open handle
on a file being moved to the Trash, and it stops when a playing copy is
ignored or scrolled out of the results by a rescan.

Group IDs gain a suffix when audio splits a group, which deliberately resets
any "ignore indefinitely" entry for the original group — the new groups are not
the group the user chose to ignore.

## Status

Implemented end-to-end:

- `AudioFingerprintMatcher` — fingerprint model, alignment/BER scoring, clustering.
- `AudioFingerprintExtractor` — parallel `fpcalc -raw` extraction with the
  safe-attribution fallback and per-file failure isolation.
- `AudioFingerprintCache` — binary on-disk cache keyed by path + size + mtime.
- `FingerprintDuplicateService` — duration gating, verification, group splitting.
- `AudioFingerprintIndex` — MinHash signatures and candidate-pair generation.
- `FingerprintLibraryScanService` — whole-library scan, checkpointed and cancellable.
- `DuplicateTracksView` — verify card, whole-library scan, progress, per-group badges.

Verified on real audio: six identically-tagged files reduce to the four that
are genuinely one recording — one decoy rejected by the duration gate without
being decoded, and a second, padded to a matching duration, rejected by audio.
A rescan off the cache was 11x faster.

Possible follow-ups:

- Reuse cached fingerprints for the AcoustID metadata lookup, which currently
  re-runs `fpcalc` for its own compressed fingerprint.
- Stream fingerprints from the cache during comparison instead of holding them
  all in memory, if libraries grow well past 50k.
- Offer to repair tags on an "Audio match · tags differ" group by copying the
  most complete copy's metadata onto the rest, rather than only deleting.

## Requirements

`fpcalc`, from Chromaprint:

```
brew install chromaprint
```

No API key and no network access are needed for duplicate detection.
