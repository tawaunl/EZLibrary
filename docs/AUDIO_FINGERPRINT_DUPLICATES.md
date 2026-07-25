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

## Status

Implemented:

- `AudioFingerprintMatcher` — fingerprint model, alignment/BER scoring, clustering.
- `AudioFingerprintExtractor` — parallel `fpcalc -raw` extraction with the
  safe-attribution fallback and per-file failure isolation.

Not yet built:

- The on-disk fingerprint cache described above.
- Wiring into `DuplicateTracksService` to confirm or split metadata groups.
- `DuplicateTracksView` surfacing (confidence badge, scan progress).

## Requirements

`fpcalc`, from Chromaprint:

```
brew install chromaprint
```

No API key and no network access are needed for duplicate detection.
