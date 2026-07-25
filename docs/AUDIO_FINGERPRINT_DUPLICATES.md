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

## Versions are not duplicates

A DJ edit really is mostly the same audio as the track it came from, so
fingerprinting alone groups versions a DJ needs to keep apart. Measured on
real files:

| Pair | Score | |
| --- | --- | --- |
| Quick Hit vs Quick Hit (copy) | 1.000 | true duplicate |
| **Dirty vs Intro Dirty** | **0.880** | above threshold — different versions |
| **Intro Dirty vs Quick Hit** | **0.898** | 281s vs 131s, still matched |
| **Intro Clean vs Original** | **0.908** | different edits |
| Dirty vs Acapella | 0.526 | correctly separate |

Raising the threshold does not fix this. A Clean and Dirty pair differing only
by a few censored words scores higher than any re-encode, so the two
populations genuinely overlap.

So versions are separated **structurally**, by the version descriptors parsed
from the title, and an acoustic cluster becomes a `TrackVersionTree`:

```
No Diggity                      ← acoustic cluster (one recording)
├── Dirty                       ← 1 copy, never offered for deletion
├── Intro · Dirty               ← 1 copy, never offered for deletion
└── Quick Hit · Dirty           ← 2 copies, these are the duplicates
```

Only copies inside one branch are ever treated as duplicates. Each resulting
group also reports its sibling versions, so the UI can state which versions the
scan deliberately kept out.

On a 600-file slice this moved the audio scan from 144 groups/299 tracks to
139/280 — 19 tracks that are version variants are no longer offered for
deletion.

### Version labels are compound

`versionCategory` previously returned the first match only, so
"No Diggity (Dirty Acapella)" was labelled plain "Dirty" — which put the
acapella in the **same metadata duplicate group as the full dirty mix**, and
offered it for deletion. That was a pre-existing hole in the ID3 path, not just
the audio one.

Labels now carry every descriptor found — `Quick Hit · Dirty`,
`Dirty · Acapella` — because version is really several independent dimensions:
the edit, the stem, and the lyric cut.

`Mix` and `Original` are treated as generic modifiers and dropped when a real
descriptor is present, since "Extended Mix" and "Extended" are the same version.
Everything else is kept: over-splitting only costs a missed duplicate, while
over-merging can cost a version the DJ needed.

### Copies that are close but not identical

Within a branch, the lowest pairwise score decides confidence. At or above
0.95 (re-encodes measure 0.976-1.000) copies are `identical` and safe to
auto-select. Below it they are `similar` — still shown, but flagged "listen
before deleting" and never pre-selected.

## What deleting actually does

"Delete → Computer" runs in this order:

1. **Refuse if Serato is running**, before anything is touched. The crate
   writer already refused in this case, but it refused *after* the files were
   trashed, leaving the library and crates pointing into the Trash.
2. Work out which files may be trashed — see below.
3. Snapshot and rewrite `database.db`.
4. Snapshot and reconcile every affected crate.
5. **Only then** move files to the Trash, one at a time.

Library and crates are written *before* any file is trashed, so a failure
there leaves the user exactly where they started. The reverse order can strand
files in the Trash with the library still referencing them. A file that can't
be trashed is reported by name rather than aborting the rest — the library
edit has already succeeded either way.

Files go to the Trash via `trashItem`, never unlinked, so everything is
recoverable from Finder.

`DuplicateDeletionPlanner` decides what may be trashed, and lives in the core
rather than the view so these rules are testable:

- A file a **surviving** library entry still points at is never trashed. A
  library can hold two entries for one file, and trashing it would break the
  entry the user chose to keep.
- Files already gone are skipped.
- One file is never trashed twice, even when several deleted entries point at
  it.
- Paths are compared after standardizing, so `a/../b.mp3` and `b.mp3` are
  recognized as the same file.

### Results survive a delete

Deleting used to call `rebuildDuplicateGroups()`, which re-ran the *metadata*
scan and cleared every audio verdict. After deleting one group, the rest
vanished and the scan had to be run again — and because the library reload
also fires the view's `onChange` handlers, fixing the delete path alone would
not have been enough.

Results now carry their source. Metadata results are cheap, so a library
change rebuilds them. Audio results are pruned in place instead:
`removingTracks(from:where:)` drops the deleted copies, removes any group that
falls below two copies, and returns every untouched group *unchanged* so its
identity survives. That matters because audio verdicts, version siblings and
keep selections are all keyed by group id.

The prune after a delete is driven by the paths just removed rather than by
the reloaded library, so it doesn't depend on the reload landing first.

### Bulk actions are more conservative than the cards

"Delete All Others" skips any group flagged *listen before deleting* — the
copies there sound alike but aren't bit-identical, which is exactly the case
that shouldn't be swept up by one click. The bar says how many groups were
held back, and they stay deletable from their own card after a listen.

## Crates are reconciled, not just stripped

Deleting a duplicate used to remove its path from every crate. If a crate
referenced the copy being deleted and *not* the copy being kept, that silently
dropped the song from the crate, and a crate built entirely from now-deleted
copies emptied completely.

`CrateReconciliationService` re-points instead: the kept copy takes the deleted
copy's slot, in the same position, so the crate still plays the same music. If
the kept copy is already in that crate the redundant entry is simply dropped,
and any crate that would still end up empty is named in the result.

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
