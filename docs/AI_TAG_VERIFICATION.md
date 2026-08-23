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

Sources, and what each needs:

| Source | Credential | Notes |
| --- | --- | --- |
| iTunes | none | broad commercial coverage |
| MusicBrainz | none | best editorial data; 1 request/second |
| Deezer | none | catalogue plus **track length** |
| AcoustID | free key + `fpcalc` | identifies the actual audio |
| Discogs | free token | best for vinyl, bootlegs, white labels; off by default |

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

Cost is shown before the run starts. The estimate covers tokens only (Anthropic
bills web searches separately) and uses standard list prices rather than
promotional ones, so it does not come in under the real bill.

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

## The bulk button uses the same engines

"Apply Top Hit (A/Al/G/Y)" is now **"Apply Verified Tags (A/Al/G/Y)"** and runs
the tier selected in the verification sheet instead of writing iTunes' first
search result.

The old behaviour was the problem this whole feature exists to fix: for a
seven-minute extended mix, iTunes' first hit is the three-minute original
single, so the album and year it wrote belonged to a different recording.

Two properties of the old button are kept on purpose:

- **It writes only Artist, Album, Genre, and Year — never the title.** A title
  carries version descriptors, and rewriting titles in bulk without a field-by-
  field look is not something this path should do. Use the review sheet for
  titles.
- **"Only Fill Empty" still applies**, and whitespace-only values count as
  empty.

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
