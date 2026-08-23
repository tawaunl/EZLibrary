# Tag Verification

Checks whether a track's tags are actually correct for the recording in the
file, and proposes changes **only** for fields an outside source contradicts.

This is a different question from the existing online lookup. "Lookup ID3
Online" and "Apply Top Hit" ask *what does iTunes return for this search?* and
write the first result. That is fine for a chart single and wrong often enough
on everything else, because a DJ library is mostly not chart singles: it is
extended mixes, radio edits, clean/dirty versions, remixes, bootlegs, and
mashups. For those, the top hit is usually the **original commercial release** —
a different recording, with a different length, a different year, and sometimes
a different artist credit.

## Three tiers, ordered by what they cost you

Everything below stage 1 answers the same question and returns the same shape,
so the review screen is identical whichever one runs. They differ in what they
need from you.

| Tier | Needs | Cost | Works on |
| --- | --- | --- | --- |
| **Cross-source consensus** (default) | nothing | free | every supported Mac |
| **Apple on-device model** | Apple Intelligence | free | macOS 26, Apple silicon |
| **Cloud model** | your own API key | your account | every supported Mac |

The default is deliberately the one that needs no account, because a feature
only some users can reach is not a feature the app has.

## Stage 1 — offline checks (free, no key, no network)

`TagIntegrityAudit` runs deterministic checks over the selection and reports
what is already visibly wrong:

| Check | Example it catches |
| --- | --- |
| Empty required fields | no title, no artist |
| Placeholder values | `Unknown`, `Various Artists`, `Track 07`, `untitled` |
| Promo / rip text | `www.bpmsupreme.com` in the title, `Downloaded from DJcity` in the comment |
| Filename disagreement | file is `Fred again.. - Delilah.mp3`, tags say `Justice — Neverender` |
| Artist repeated in title | title is `Justice - Neverender` (YouTube rip heading) |
| Featured artist mismatch | title credits `feat. Travis Scott`, artist field does not |
| Implausible year | `1832`, `9999`, a file timestamp that leaked into the tag |
| Key or BPM in the genre field | genre is `8A` or `128` |

Stage 1 never guesses a correct value — establishing that "Hotline Bling" is by
Drake and came out in 2015 needs a source. What it does is narrow the field,
which is what makes the paid tier affordable and the slow tier bearable. The
sheet offers **"Only verify the N flagged tracks"**, on by default.

A clean stage 1 is not a clean bill of health: it catches *malformed* tags. A
well-formed tag naming the wrong recording looks fine to it, and that is exactly
what stage 2 is for — so with nothing flagged, the run falls back to the whole
selection rather than refusing to run.

## Stage 2, tier 1 — cross-source consensus

The default, and the one most users should stay on.

It asks several music databases independently and proposes a change **only
where they agree**. Agreement is a far stronger signal than ranking: if iTunes,
MusicBrainz, and Deezer separately return the same album, that album is almost
certainly right. If they disagree, no amount of ranking makes the top one true,
and the honest answer is "unverified".

The one exception is the album field, where Wikipedia is trusted as a
specialist — see "Wikipedia is the album authority" below.

Sources, and what each costs. Latencies are measured, not estimated:

| Source | Credential | Latency | On by default |
| --- | --- | --- | --- |
| iTunes | none | ~0.22s | yes |
| Deezer | none | ~0.26s (+0.27s per album lookup) | yes |
| Wikipedia | none | ~0.3s (search + one summary) | yes |
| MusicBrainz | none | 0.6s–39s, **1 request/second cap** | no |
| AcoustID | free key + `fpcalc` | ~0.3s (0.05s `fpcalc`) | no |
| Discogs | free token | rate limited | no |
| YouTube | your own API key + quota | rate limited | no |

### Why the defaults are what they are

MusicBrainz has the best editorial data and was originally in the default set.
Measured, it is the throughput ceiling for a whole-library run: its search
latency ranges from under a second to past the 10-second request timeout, and it
paces callers to one request a second, so no amount of concurrency gets past
about one track per second.

It was indispensable for one reason — it was the only free source reporting a
release year. Deezer's album endpoint reports `release_date` (and a genre) in
about a quarter of a second, so fetching that removed the dependency.

Benchmarked over six tracks, fingerprint off:

| Sources | Per track | Result |
| --- | --- | --- |
| iTunes + Deezer | **0.33s** | 18 changes, year on 6/6, art on 6/6 |
| + MusicBrainz | 2.85s | 18 changes, year on 6/6, art on 6/6 |

**8.6x faster, identical output** on that sample. MusicBrainz still earns its
place on obscure material the commercial catalogues do not carry, so it is one
toggle away rather than gone.

### Wikipedia is the album authority

The catalog APIs are reliable for title, artist, and duration, but they answer
*"what album is this track sold on?"*, which for a single is the single itself
or a later hits compilation — not the studio album the song first appeared on.
Wikipedia's prose names that original album, so the consensus reads it out of
the summary ("…from their fourth studio album *Hyperdrama* (2024)") and gives
it the final word on the album field: its album wins even when more catalog
sources agree on a different one, and it alone can fill an empty album.

The safety valve is confidence, not agreement. Filling a blank album from
Wikipedia is trusted enough to apply unattended; *overwriting* an album the
user already has is held below the auto-apply threshold, so a questionable
rewrite surfaces in the review sheet instead of being written by a bulk run.
Wikipedia carries no duration and only sometimes states a genre, so it
contributes an album and a year and leaves identity to the sources that report
length. It is not rate limited, so it enriches the album without lowering the
run's throughput ceiling.

YouTube is the mirror image: a genre-of-last-resort that needs your own API key
and spends quota, so it is never on by default and contributes only a genre it
can read from a video's title and description.

The audio fingerprint is off by default for a different reason: at ~0.3s per
track it is not expensive, it simply buys nothing for a track whose identity the
databases already agree on. It earns its keep on files too badly tagged to
search with — a rescue pass, not a library sweep.

### Where the remaining time goes

Measured at **0.24s per track** on the fast pair — roughly four minutes for a
thousand tracks. Two things were tried and one worked:

- **Track concurrency does nothing.** 24 tracks took 7.4s at width 3 and 7.3s at
  width 8. The pipeline is bound by per-source request pacing, not by how many
  tracks are in flight, so widening only builds a queue. The default now derives
  width from the sources rather than pretending more is better.
- **Fetching one Deezer album instead of two cut 20%** (0.30s → 0.24s per track)
  and filled exactly the same number of years and genres. The top result's album
  is the one that matters; the second lookup only bought requests.

What is left is iTunes' own rate limit. Going faster means dropping a source,
which costs corroboration — so the honest lever for a big library is the stage 1
pre-screen, not more parallelism.

Three guards keep it from confidently proposing the wrong recording:

- **Distinct sources, not distinct results.** Five iTunes rows agreeing with
  each other is one opinion. Counting rows would rebuild the top-hit problem
  with extra steps.
- **Duration.** A radio edit and an extended mix share a title and differ by
  minutes. Candidates whose length cannot match the file are discarded *before*
  anything is counted. This is the single most effective filter for a DJ
  library, and it is why Deezer earns its place — it is the free source that
  reports length.
- **Version descriptors.** `(Extended Mix)`, `(Dirty)`, `(Rampa Remix)` are part
  of what the DJ owns. A consensus title never strips one; the descriptor from
  the current title is re-attached to the proposal.

Confidence comes from how many independent sources agreed, plus a bump when the
audio fingerprint is one of them. It means something specific, which is why
proposals at 0.75 and above are pre-checked.

### Year is a special case

The sources are not answering the same question. Measured against the live APIs
for one track (Daft Punk — Around The World): iTunes returns the date of *the
release it matched* (1997), MusicBrainz returns the recording's *first* release
date (1996), and Deezer's search results carry no date at all.

Requiring exact agreement therefore left year unverified on almost everything —
two sources, two different questions, one apparent disagreement, nothing
proposed. Years within a year of each other are now treated as corroborating the
same record, and the earliest is taken: that is the original release year, which
is the convention a library tags to. A genuine gap — a 1977 original against a
2015 remaster — is far wider than the tolerance, so those still do not merge,
and the earliest is the right answer there anyway.

### Empty fields accept a single source

Filling a blank is a different risk from overwriting a value someone chose, so
one source is enough to *suggest* into an empty field. That carries 0.5
confidence, which sits below the auto-apply bar — it appears in the review sheet
for you to accept, and a bulk run will not write it unseen.

### Cover art

Art is offered only when the file has **no embedded cover at all**, so applying
it fills a gap and never replaces a cover you chose. It is taken from the
release the other fields agreed on — picking purely by image size once attached
a remixes-EP cover to a track whose album consensus was a different record.
Within that release, the largest available image wins (Deezer serves 1000px,
iTunes 600px, MusicBrainz whatever the Cover Art Archive holds), because
embedded art gets looked at on phones and controllers.

Artwork is applied from the **review sheet only** — the bulk button writes text
fields and nothing else.

## Stage 2, tier 2 — Apple on-device model

Free, private, and needs no key, but only on macOS 26 with Apple Intelligence
available.

The on-device model is around three billion parameters and is explicitly not
built for world knowledge — asking it what year a record came out gets a
confident guess, which is worse than no answer. So it is never asked to recall
anything. It is given a **tool** that searches the same free databases the
consensus tier uses, and its job is the part it is genuinely good at: reading
the evidence and deciding which candidate matches the file in front of it.

That division is what makes "AI that searches" work with no API key — the app
does the searching, the model does the judging, and nothing leaves the Mac
except the same database queries the consensus tier already makes.

Expect roughly 5–25 seconds per track. Runs are deliberately serial: parallel
sessions contend for the same neural engine and finish no sooner while making
the machine unusable for anything else.

### What a small model gets wrong, and the guards for it

All three of these are observed behaviour from live runs, not hypotheticals:

- **It put the artist in the title.** Asked to correct the title of
  `Justice - D.A.N.C.E. (Extended Mix).mp3`, it returned
  `Justice - D.A.N.C.E (Extended Mix)` — artist included, and a lost full stop.
  Applying that would corrupt the field it was asked to fix. Proposed titles now
  have a leading `Artist - ` stripped in code, and a dropped version descriptor
  re-attached.
- **Its confidence numbers were inverted.** Asked for a 0–1 float it returned
  `0.00` on exactly the verdicts it was proposing to change and `1.00` on the
  ones it was leaving alone. It now picks from a constrained `high`/`medium`/
  `low` enum, which a small model can actually place a judgement in, mapped to
  fixed scores.
- **It called an empty tag "correct"**, citing a source that carries no genre at
  all. An empty tag can never be "correct" — there is nothing there to be right
  — so that verdict is downgraded to "unverified" in code.

The prompt asks for the right behaviour in each case; the code makes sure of it.

## Stage 2, tier 3 — cloud model, your key, any provider

The strongest tier on the hard tail — bootlegs, edits, and white labels that no
database carries — because it can search the open web.

Two providers:

- **Anthropic (Claude)**, natively. The only one offering a *server-side web
  search*, which is the whole reason to reach for a cloud model over the free
  tiers. Model selectable; Opus 5 by default.
- **Anything speaking OpenAI's `/chat/completions` shape** — OpenAI, OpenRouter,
  Groq, Mistral, DeepSeek, and locally-run models under **Ollama** or **LM
  Studio**. A base URL and a model name reach all of them. A local model needs
  no key and costs nothing, so this doubles as a second free tier for anyone
  already running one.

Providers reached through the OpenAI-compatible path cannot search the web. They
still receive the full evidence bundle — fingerprint match, database candidates,
filename, current tags, stage 1 findings — so they have real material to judge;
they simply cannot go and look anything else up.

### What it actually costs

Measured over ten tracks on Opus 5, August 2026 — not estimated:

| | With web search | Without |
| --- | --- | --- |
| Input tokens / track | 28,700 | 2,600 |
| Output tokens / track | 1,700 | 1,220 |
| Web searches / track | 1.7 | 0 |
| **Cost / track** | **$0.203** | **$0.044** |
| Time / track | 17.4s | 3.6s |

So roughly **$20 per hundred tracks** with search, or **$4.35** without. Sonnet 5
is about a third less, Haiku 4.5 about a quarter of Opus.

Web search is the whole story: it multiplies input tokens by **eleven**, and
searches are billed on top of tokens at $10 per 1,000. The first version of this
estimator assumed search merely quadrupled the input and ignored the search fee
entirely, and consequently quoted about half the real price.

The sheet shows a running total of **actual** spend during a cloud run —
reported from each reply's own usage, not projected — so the estimate only has
to be right enough to decide with.

### The schema and web search do work together

This was the one genuinely unverified thing about the cloud tier for a long
while: structured outputs are documented as incompatible with citations, and web
search results carry citations, so `output_config.format` and
`web_search_20260209` might well have been mutually exclusive. A fallback exists
that retries without the schema and reports having done so.

Confirmed by the live run: **ten of ten requests succeeded with the schema
intact and the fallback never fired.** The two compose.

### Per-model request differences (Anthropic)

The Messages API surface is not uniform across models, and a model switch must
not turn into an HTTP 400 the user cannot interpret. `ClaudeModel` encodes it:

| | Opus 5 | Sonnet 5 | Haiku 4.5 |
| --- | --- | --- | --- |
| `thinking: {type: "adaptive"}` | yes | yes | rejected — omitted |
| `output_config.effort` | yes | yes | rejected — omitted |
| Server-side refusal `fallbacks` | yes | omitted | omitted |
| Web search tool | `web_search_20260209` | `web_search_20260209` | `web_search_20250305` |

`ClaudeAPIClient` also handles two behaviours that are easy to get wrong:
**`pause_turn`** (the server-side search loop has an iteration cap; the paused
assistant turn is echoed back verbatim to resume, and adding a "continue"
message would derail it) and **throttling** (429 honours `retry-after`;
429/529/5xx retry with backoff).

## Filling every field, and keeping the version

The goal is a library where **title, artist, album, genre, and year are all
populated**. Two rules get there without turning it into a guessing machine:

- **An empty field is filled on weaker evidence than a populated one is
  overwritten.** One source is enough to fill a blank (confidence 0.5); replacing
  a value the user already has still needs corroboration (0.75). Filling a blank
  cannot destroy anything. "Lower bar" is not "no bar" — a near-guess is still
  refused.
- **Version wording always survives.** Every engine's title correction passes
  through one choke point in `TrackTagVerification.metadataUpdate(applying:)`,
  which re-attaches any DJ descriptor the current title carries. The databases
  return the plain song title, so a correction that is right about the *song* is
  still destructive if it drops the *version* — and it is the version that says
  which cut of the record this is. Enforcing it there means no engine, present
  or future, can lose one regardless of what its prompt or scoring says.

Searching already ignores those descriptors (`searchableTerm` strips them before
querying), so "Neverender (Extended Mix)" is looked up as "Neverender" and the
descriptor is put back on the way out.

### Identity confidence

Nothing is auto-applied unless the engine was confident it identified the right
recording, because a confident verdict about the wrong recording is still wrong.

That confidence rests on how many sources independently agreed on **title and
artist together**, plus whether a source reporting a length matched the file's.
It deliberately does *not* count how many sources merely answered — three
sources naming three different songs is not three-fold confidence.

This distinction stopped being academic when the default source set shrank to
two: an earlier scale keyed on reply count returned 0.65 for two sources, just
under the 0.7 floor, so every bulk apply was silently refused no matter how well
the sources agreed.

### One subtlety worth knowing

Candidate lists are **not deduplicated** before consensus counts them. Collapsing
identical records across sources is right for a picker a human chooses from, and
destroys the entire signal here: two sources independently returning the same
album *is* the corroboration. `lookup(deduplicate:)` exists for exactly this
distinction.

## The bulk button uses the same engines

"Apply Top Hit (A/Al/G/Y)" is now **"Apply Verified Tags (A/Al/G/Y)"** and runs
the tier selected in the verification sheet instead of writing iTunes' first
search result.

The old behaviour was the problem this whole feature exists to fix: for a
seven-minute extended mix, iTunes' first hit is the three-minute original
single, so the album and year it wrote belonged to a different recording.

It writes all five fields, including the title — safe because every title
correction goes through the descriptor-preserving choke point described above.
**"Only Fill Empty" still applies**, and whitespace-only values count as empty.

On top of those it now gates on confidence: a proposal is written only if it
clears the engine's threshold (0.75 for consensus and cloud, 0.85 for the
on-device model) *and* the engine was confident it identified the right
recording at all. Anything below that is simply not applied — the run reports
"nothing was confident enough to change" rather than writing a guess.

Because verifying is no longer nearly free, the button confirms before it
starts whenever the tier is paid or more than 25 tracks are selected, showing
the engine, the cost, and a time estimate. A running job shows a live
`done / total` count and can be stopped partway, keeping what it already found.

"Fill Missing Genre/Year" still uses the older single-source lookup.

## Runs keep going while you work

A verification belongs to the app, not to the review window. Close the sheet and
the run carries on; the Tags view shows a banner with live progress, a **Show**
button to reopen it, and **Stop**. When it finishes, the banner turns into
*"N proposed changes across M tracks ready to review"*. Reopening finds the
results, and the ticks you had already made, exactly as you left them.

That matters because a run is not instant: the on-device model is seconds per
track, and a library-sized consensus pass is minutes. Holding that state in the
window meant closing it threw the work away.

Applying is unchanged in spirit — nothing is written until you press Apply — but
the sheet now gets out of the way afterwards: with the run finished it closes,
and mid-run it drops the tracks it just wrote so what remains is the outstanding
work.

## What the searches actually use

**The file's own ID3 tags.** Not the filename, and not the library's stored copy
of the tags. The database row is what Serato read at import, and anything that
edited the file since has not necessarily told Serato, so the file is the
current truth about what a track claims to be. Where the file has no value for a
field, the library's copy fills the gap.

The filename is still shown to the AI tiers, but explicitly labelled as a weak
hint that must never be copied into a field — a small model reproduces whatever
looks most like an answer, and `Artist - Title.mp3` looks exactly like one.

## House rules the engines follow

- **Version wording is preserved, always.** Enforced in code at the single point
  every engine's title change passes through, not merely asked for in a prompt.
- **Hip hop is spelled "Hip Hop".** The sources return "Hip-Hop/Rap",
  "Rap/Hip Hop" and "hip hop" for the same genre. They are canonicalised *before
  being counted*, so three sources spelling it three ways register as three
  sources agreeing rather than three disagreeing, and *again on write*, so the
  library ends up with one spelling.
- **A remix keeps the original song's year — unless it is electronic.** Outside
  electronic music a remix is still that record, so it carries the year the song
  came out. In house, techno, drum & bass, trance and the like a remix is a
  release in its own right and keeps its own date. A title only counts as a
  version when the marker is inside brackets or after a dash, so a song called
  "Remix Culture" is not mistaken for one.

## Nothing is written until you apply it

A verdict is a proposal with a source attached, not an instruction. The review
sheet lists every proposed change with its confidence, its one-line evidence,
and a link to the page it came from where there is one. Proposals above the
tier's confidence bar are pre-checked; everything else is opt-in. Applying goes
through the same `SeratoTrackMetadataUpdate` batch writer as every other tag
edit, so the usual backup, atomic-write, and Serato-is-running protections apply
unchanged.

An engine's identity confidence gates pre-selection too: a confident verdict
about the wrong recording is still wrong.

## Privacy

| Tier | What leaves your Mac |
| --- | --- |
| Stage 1 offline checks | nothing |
| Cross-source consensus | search terms (title/artist/album), and an audio fingerprint if AcoustID is on |
| Apple on-device model | the same database searches — the model itself runs locally |
| Cloud model | the track's tags, filename, duration, and the candidates the databases returned |

No tier sends audio. AcoustID sends a compressed fingerprint, never the file.
Everything is opt-in and per-action; nothing is sent when the sheet is merely
open.

## Configuration

| Setting | Where |
| --- | --- |
| Verification tier | chosen in the sheet, remembered per user |
| Cloud provider, model, base URL, key | Settings → API Keys |
| Anthropic key | Settings → API Keys, or `EZLIBRARY_ANTHROPIC_KEY` |
| OpenAI-compatible key | Settings → API Keys, or `EZLIBRARY_OPENAI_COMPATIBLE_KEY` |
| AcoustID key | Settings → API Keys, or `EZLIBRARY_ACOUSTID_KEY` |
| Discogs token | Settings → API Keys, or `EZLIBRARY_DISCOGS_TOKEN` |

A saved key takes precedence over the environment variable.

## Where the code lives

| File | Role |
| --- | --- |
| `Services/TagIntegrityAudit.swift` | Stage 1 — offline checks |
| `Services/TagConsensusService.swift` | Tier 1 — cross-source agreement |
| `Services/OnDeviceTagVerificationService.swift` | Tier 2 — Apple on-device model |
| `Services/AITagVerificationService.swift` | Tier 3 — evidence bundle, prompt, verdict parsing |
| `Services/ClaudeAPIClient.swift` | Anthropic Messages API over `URLSession` |
| `Services/OpenAICompatibleClient.swift` | Any OpenAI-compatible endpoint |
| `Services/TagVerificationCoordinator.swift` | Tier selection and availability |
| `Models/TagVerification.swift` | The shared verdict shape every tier returns |
| `Views/AITagVerificationSheet.swift` | Review UI |

There is no official Anthropic SDK for Swift, so `ClaudeAPIClient` speaks the
HTTP API directly and the package keeps its zero-dependency build.

## Settings live in more than one place

`UserDefaults.standard` keys off the bundle identifier for a packaged app
(`com.seratotools.app`) and off the executable name for a plain binary
(`EZLibrary` under `swift run`), and this project was previously called
SeratoTools. The same person can therefore end up with API keys and preferences
in three separate plists, and whichever build they launch sees only its own.

The symptom is not an error, it is worse: settings that look saved but have no
effect. An Anthropic key entered in one build leaves the other reporting "no API
key", and a cloud engine chosen in one silently runs the free one in the other.

`LegacyDefaultsMigration` runs once at launch and adopts any `SeratoTools*` key
from the legacy domains that the current domain does not already have. It never
overwrites, and it runs only once so a setting the user deliberately cleared does
not reappear.

Relatedly, the engine fallback is no longer silent: when the chosen tier cannot
run, the run says which tier it wanted, why it could not, and what it used
instead, rather than quietly producing free-tier results that look like paid ones.

> **Note for anyone writing tests that touch defaults:** use
> `TestDefaults.inMemory()`, never `UserDefaults(suiteName:)`. A named suite is a
> real file in `~/Library/Preferences` that survives `removePersistentDomain`
> (which empties the domain but leaves the file), and the preferences daemon can
> rewrite it after deletion — so such a test cannot reliably clean up after
> itself. It also searches the process's application domain, which under
> `swift test` resolves to a real domain, so it can read and overwrite the
> machine's actual saved settings. Code that genuinely exercises
> `persistentDomain(forName:)` should take an injectable reader, as
> `LegacyDefaultsMigration.migrate(contentsOfDomain:)` does.
