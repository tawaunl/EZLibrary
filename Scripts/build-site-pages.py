#!/usr/bin/env python3
"""Generate the feature pages for the EZLibrary site.

The ten feature pages share a layout, a sidebar and a footer, so they are
generated from the FEATURES table below rather than hand-maintained ten times
over. This script is the source of truth for `site/features/` — edit the table,
re-run the script, and commit the result.

    ./Scripts/build-site-pages.py

Content strings are inserted as-is and may contain inline HTML.
"""

from __future__ import annotations

import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT = ROOT / "site" / "features"

REPO = "https://github.com/tawaunl/EZLibrary"
RELEASES = f"{REPO}/releases/latest"


class Feature:
    def __init__(
        self,
        slug: str,
        name: str,
        nav: str,
        tagline: str,
        status: str = "Shipped",
        status_class: str = "badge",
        shot: str | None = None,
        shot_alt: str = "",
        shot_title: str = "",
        intro: tuple[str, ...] = (),
        does: tuple[tuple[str, str], ...] = (),
        steps: tuple[tuple[str, str], ...] = (),
        note: str | None = None,
        related: tuple[str, ...] = (),
        blurb: str = "",
        icon: str = "",
    ):
        self.slug = slug
        self.name = name
        self.nav = nav
        self.tagline = tagline
        self.status = status
        self.status_class = status_class
        self.shot = shot
        self.shot_alt = shot_alt
        self.shot_title = shot_title or name
        self.intro = intro
        self.does = does
        self.steps = steps
        self.note = note
        self.related = related
        self.blurb = blurb or tagline
        self.icon = icon


ICON = {
    "tag": '<path d="M20.6 13.4l-7.1 7.1a2 2 0 01-2.9 0l-7.2-7.2A2 2 0 013 12V5a2 2 0 012-2h7a2 2 0 011.4.6l7.2 7.2a2 2 0 010 2.6z"/><circle cx="7.5" cy="7.5" r="1.3"/>',
    "copy": '<rect x="8" y="8" width="13" height="13" rx="2.2"/><path d="M16 8V5a2 2 0 00-2-2H5a2 2 0 00-2 2v9a2 2 0 002 2h3"/>',
    "search": '<circle cx="11" cy="11" r="7"/><path d="M20 20l-3.6-3.6"/>',
    "crate": '<path d="M3 7l9-4 9 4-9 4-9-4z"/><path d="M3 12l9 4 9-4M3 17l9 4 9-4"/>',
    "note": '<path d="M9 18V5l11-2v13"/><circle cx="6" cy="18" r="3"/><circle cx="17" cy="16" r="3"/>',
    "folder-plus": '<path d="M4 20V8a2 2 0 012-2h4l2 2h6a2 2 0 012 2v10a2 2 0 01-2 2H6a2 2 0 01-2-2z"/><path d="M12 11v6M9 14h6"/>',
    "folder-down": '<path d="M3 5h6l2 3h10v11a2 2 0 01-2 2H5a2 2 0 01-2-2V5z"/><path d="M12 17V11M9 14l3 3 3-3"/>',
    "history": '<path d="M12 3a9 9 0 108.5 6"/><path d="M21 3v6h-6"/><path d="M12 8v4l3 2"/>',
    "pencil": '<path d="M12 20h9"/><path d="M16.5 3.5a2.1 2.1 0 013 3L7 19l-4 1 1-4 12.5-12.5z"/>',
    "terminal": '<path d="M4 17l6-5-6-5"/><path d="M12 19h8"/>',
}


FEATURES: list[Feature] = [
    Feature(
        slug="tracks-and-tags",
        name="Tracks &amp; Tags",
        nav="Tracks &amp; Tags",
        icon="tag",
        tagline="Browse the whole library, fix metadata in place, and fill thousands of empty fields in one pass.",
        shot="shot-tracks.webp",
        shot_title="Tracks &amp; Tags",
        shot_alt="The Tracks and Tags workspace: a sortable library table with completion stats above it and a bulk edit bar.",
        intro=(
            "Tracks &amp; Tags is where most sessions start. It is one table over your entire "
            "Serato library — or over a single crate — with every editing tool applied to "
            "whatever you have selected.",
            "The completion stats across the top are the fastest way in. They show what "
            "percentage of the current scope has an artist, album, genre and year, and "
            "clicking one filters the table down to exactly the tracks that are missing it.",
        ),
        does=(
            ("Search, sort and scope", "Filter by text, sort by any column, and switch between your whole library and a single crate without leaving the view."),
            ("Click a stat to filter", "<em>Genre Filled 78%</em> is also a button — click it and you are looking at the other 22%. Click again to clear."),
            ("Bulk fill", "Set artist, album, genre or year across every selected track at once. <strong>Only Fill Empty</strong> protects values that are already there."),
            ("Online lookup", "Pull correct metadata and cover art from iTunes, MusicBrainz and Discogs, with fingerprint-assisted suggestions when the tags are too sparse to search on."),
            ("DJ-safe titles", "Version markers like (Intro), (Clean) and (Extended Mix) are preserved when an online title is applied, instead of being flattened to the radio edit."),
            ("Listen before you commit", "The built-in player has full transport controls and follows the order of the list you are looking at, filters and sort included."),
            ("Copy anything", "Every value in the app is selectable text, so you can lift an ISRC or a path straight out of the window."),
        ),
        steps=(
            ("Pick your scope", "Choose <em>All Tracks</em> or a specific crate at the top of the view."),
            ("Find what is broken", "Click a completion stat to filter to the tracks missing that field, or search for the mess you already know about."),
            ("Select and edit", "Select the rows you want. Use bulk fill for values you know, or online lookup to fetch them."),
            ("Apply", "Changes are written to the audio files and to Serato together, with a backup taken first. Serato has to be closed."),
        ),
        note="Serato rewrites its library from memory when it quits, so it would overwrite anything "
             "changed underneath it. EZLibrary refuses to write while Serato is running rather than "
             "let that happen.",
        related=("rename", "duplicates", "crates"),
    ),
    Feature(
        slug="duplicates",
        name="Find Duplicates",
        nav="Find Duplicates",
        icon="copy",
        tagline="Catch the same song saved five times, even when every copy is named differently.",
        shot="shot-duplicates.webp",
        shot_title="Duplicates",
        shot_alt="The Duplicates workspace showing groups of duplicate tracks with completeness scores and keep-best controls.",
        intro=(
            "Pool downloads, re-rips and files dragged in from an old drive leave you with the "
            "same track several times over, usually under names that do not match. Filename "
            "comparison misses most of them.",
            "EZLibrary compares the audio itself. It generates an acoustic fingerprint for each "
            "file, so two copies of the same recording group together regardless of what the "
            "tags or filenames say.",
        ),
        does=(
            ("Audio fingerprint matching", "Offline fingerprinting with Chromaprint groups tracks by what they actually sound like, not by metadata."),
            ("Whole-library scan", "Scan everything in one go. Results are cached, so a repeat scan is fast."),
            ("Version-aware", "Intro, Clean, Dirty, Extended, Remix and Edit markers keep versions in separate groups — an Extended Mix is not a duplicate of the original."),
            ("Completeness scoring", "Each copy is scored on how complete its metadata is, so <strong>Pick Best</strong> keeps the one worth keeping."),
            ("Two kinds of delete", "Remove a copy from the Serato library only, or delete the file from your computer as well. Both are explicit choices."),
            ("Crates stay intact", "Removing a redundant copy reconciles the crates that referenced it instead of leaving a dead entry behind."),
        ),
        steps=(
            ("Run a backup first", "Duplicate cleanup deletes things. Take a full snapshot from the Backup tab before the first run."),
            ("Scan", "Start a library scan and let the fingerprinting finish. Groups appear as they are found."),
            ("Review each group", "Check the audio verification detail and the completeness score. Groups you are unsure about can be left alone."),
            ("Keep the best", "Use Pick Best, or choose the keeper by hand, then delete the rest from the library or from disk."),
        ),
        note="Fingerprinting needs <code>fpcalc</code>, which ships inside the app — there is nothing "
             "to install. The optional AcoustID lookup needs your own free API key.",
        related=("tracks-and-tags", "backup", "consolidation"),
    ),
    Feature(
        slug="missing-tracks",
        name="Missing Tracks",
        nav="Missing Tracks",
        icon="search",
        tagline="Find every file Serato has lost track of, and relink it to where it actually lives.",
        shot="shot-missing.webp",
        shot_title="Missing Tracks",
        shot_alt="The Missing Tracks workspace listing unresolved file references with suggested replacement locations.",
        intro=(
            "Move a folder in Finder, rename a drive, or reorganise your music once, and Serato "
            "loses the thread. Tracks show as <em>cannot be located</em>, and everything attached "
            "to them — cues, loops, beat grid, play count, crate membership — goes with them.",
            "Missing Tracks scans your library for references that no longer resolve, then looks "
            "for where each file went. Fixes are applied per-track, only when you say so.",
        ),
        does=(
            ("Full library scan", "Every unresolved reference in <code>database V2</code> and in your crates, in one list."),
            ("Candidate matching", "Likely new locations are found by filename and file size, so a moved or renamed file can be reconnected."),
            ("Explicit fixes only", "Nothing is repaired silently. You apply each fix, and anything ambiguous is reported rather than guessed at."),
            ("Repairs in place", "The existing library row is re-pointed instead of being replaced, so cues, beat grids and crate membership survive the repair."),
            ("Review crate", "Send whatever could not be resolved to a crate so you can work through it inside Serato later."),
            ("Bulk repair from the CLI", "For a library knocked badly out of sync by an old move, <code>EZLibraryCLI repair-locations</code> does the same job across thousands of entries at once."),
        ),
        steps=(
            ("Mount your drives", "Anything on external storage has to be connected, or its tracks look missing when they are not."),
            ("Scan", "Run the scan from the Missing Tracks tab and let it finish."),
            ("Review candidates", "Each missing track shows the file EZLibrary believes it now points to. Confirm the ones that look right."),
            ("Apply, then check in Serato", "Apply the fixes with Serato closed, then reopen Serato and confirm the tracks resolve."),
        ),
        note="If a whole library was moved at once, try the CLI first: <code>swift run EZLibraryCLI "
             "repair-locations --search /Volumes/Music</code> previews the whole repair without "
             "writing anything. Add <code>--apply</code> when the preview looks right.",
        related=("consolidation", "crates", "backup"),
    ),
    Feature(
        slug="crates",
        name="Crates",
        nav="Crates",
        icon="crate",
        tagline="Your whole crate tree, including smart crates and the hidden ones, with real stats.",
        shot="shot-crates.webp",
        shot_title="Crates",
        shot_alt="The Crates workspace with a nested crate tree on the left and the selected crate's tracks on the right.",
        intro=(
            "The Crates workspace reads your crate structure straight off disk — nested crates, "
            "smart crates and the crates Serato keeps out of sight — and shows them as one tree.",
            "It is also the scope selector for the rest of the app. Pick a crate here and tag "
            "editing, duplicate detection and backup can all be pointed at just that crate.",
        ),
        does=(
            ("The full tree", "Nested crates are rebuilt from Serato's naming scheme, so you see the hierarchy you actually built."),
            ("Smart crates too", "Rule-based crates are read alongside regular ones, and their rules are preserved whenever EZLibrary rewrites a path inside them."),
            ("Hidden crates", "Crates Serato hides are still shown, because they still hold tracks and still break."),
            ("Fast filtering", "Filter within a crate and sort by any column to find what you are after."),
            ("Crate-scoped operations", "Use a crate as the scope for bulk tag edits, duplicate scans and single-crate backups."),
            ("Safe deletes", "Deleting a crate moves it to the Trash rather than destroying it."),
        ),
        steps=(
            ("Open Crates", "The tree loads from your <code>_Serato_</code> folder — no import step."),
            ("Select a crate", "Its tracks appear on the right, with the same table and player as the main library view."),
            ("Use it as a scope", "Switch to Tracks &amp; Tags, Duplicates or Backup and the crate stays selected as the scope."),
        ),
        related=("playlistmatch", "tracks-and-tags", "backup"),
    ),
    Feature(
        slug="playlistmatch",
        name="PlaylistMatch",
        nav="PlaylistMatch",
        icon="note",
        tagline="Paste a playlist, find out what you already own, and get a crate out of it.",
        shot="shot-playlistmatch.webp",
        shot_title="PlaylistMatch",
        shot_alt="The PlaylistMatch workspace showing a pasted playlist matched against the library with per-track confidence.",
        intro=(
            "You hear a set, you find the playlist, and then you spend an hour working out which "
            "of those forty tracks you already have. PlaylistMatch does that part.",
            "Paste a Spotify or Apple Music link, a CSV, or just a list of track names. Every "
            "entry is matched against your Serato library with a confidence score, matches become "
            "a crate, and everything you are missing goes into a plan you can work through.",
        ),
        does=(
            ("Takes any list", "Spotify and Apple Music playlist URLs, CSV rows, or plain text pasted in."),
            ("Confidence scoring", "Each match shows how sure it is, and where you own several versions of a track you choose which one counts."),
            ("Remix and version aware", "Remix and version titles are matched against their library originals rather than being treated as different songs."),
            ("Crate from matches", "Turn everything you confirmed into a new crate in one step."),
            ("A plan for the rest", "Unmatched tracks stay in a queue so the ones you do not own yet are not just lost."),
            ("Buy links that are real", "Confirmed iTunes and Beatport listings, grouped by store with per-version options — not a search URL that might find nothing."),
            ("Import what you bought", "<strong>I bought it</strong> brings the purchased file into your library, and a Downloads-folder watcher offers to import finished downloads automatically."),
            ("Download fallback", "For tracks that cannot be bought, pull the audio from YouTube or SoundCloud, with music videos filtered out of the suggestions."),
        ),
        steps=(
            ("Paste the playlist", "Drop in a link, a CSV, or a plain list of tracks."),
            ("Match", "Review the results. Fix any low-confidence rows and pick versions where you own more than one."),
            ("Create the crate", "Confirmed matches become a crate in your Serato library."),
            ("Work the plan", "For the rest, use the buy links, then import each purchase back in."),
        ),
        note="Personalised Spotify mixes (Discover Weekly and similar) are flagged, because they are "
             "generated per-listener and cannot be read back exactly.",
        related=("add-music", "crates", "tracks-and-tags"),
    ),
    Feature(
        slug="add-music",
        name="Add Music",
        nav="Add Music",
        icon="folder-plus",
        tagline="Get new files into your library and into the right crate, without the drag-and-drop dance.",
        intro=(
            "New music arrives in a Downloads folder, in a zip, or on a USB stick, and getting it "
            "filed properly is the boring part. Add Music imports files or whole folders into your "
            "music directory and assigns crates in the same step.",
            "It also installs a Finder Quick Action, so you can right-click files anywhere on your "
            "Mac and send them straight to your library without opening the app.",
        ),
        does=(
            ("Files or folders", "Point it at a folder and it finds supported audio recursively, however deeply it is nested."),
            ("Move or copy", "Move files into your library folder, or copy them and leave the originals where they are."),
            ("Crate on import", "Create a dated crate, add to an existing crate, or import with no crate at all."),
            ("Every common format", "<code>mp3</code>, <code>m4a</code>, <code>aac</code>, <code>wav</code>, <code>aif</code>, <code>aiff</code>, <code>flac</code>, <code>alac</code> and <code>ogg</code>."),
            ("Right-click from Finder", "The <em>Add to EZLibrary</em> Quick Action imports the selection using your saved defaults."),
            ("Scriptable", "The same import runs from the CLI, so it can be wired into whatever else you use."),
        ),
        steps=(
            ("Choose your source", "Select the files or the folder you want to bring in."),
            ("Pick move or copy", "Move keeps one canonical copy in your library folder; copy leaves the source untouched."),
            ("Choose a crate", "A dated crate is the default and makes new music easy to find later."),
            ("Import", "Files are placed in your music directory and registered with Serato."),
        ),
        note="Install the Finder Quick Action once with "
             "<code>/Applications/EZLibrary.app/Contents/Resources/scripts/install-finder-quick-action.sh</code>. "
             "Its behaviour is configured with the <code>EZLIBRARY_ADD_MODE</code>, "
             "<code>EZLIBRARY_ADD_DESTINATION</code> and <code>EZLIBRARY_ADD_CRATE_PREFIX</code> "
             "environment variables.",
        related=("playlistmatch", "consolidation", "cli"),
    ),
    Feature(
        slug="consolidation",
        name="Library Consolidation",
        nav="Consolidation",
        icon="folder-down",
        tagline="Pull music scattered across drives and folders into one place, without breaking a single crate.",
        intro=(
            "Most libraries end up spread across a Downloads folder, two external drives, an old "
            "Music folder and a desktop folder called <em>new</em>. That is fine until a drive is "
            "not plugged in, or you try to back the whole thing up.",
            "Consolidation maps where your files actually are, moves or copies them into one "
            "destination, and rewrites every Serato path as it goes — so nothing goes missing on "
            "the way.",
        ),
        does=(
            ("See the sprawl", "Every source folder your library references, with how many tracks and how much data sits in each."),
            ("Choose what to pull in", "Select source groups individually. You do not have to consolidate everything at once."),
            ("Move or copy", "Move for a genuine consolidation, copy to build a second complete library."),
            ("Capacity checked first", "The destination is validated against the size of what you selected before anything moves."),
            ("Paths rewritten as it goes", "Serato's library, plain crates and smart crates are all updated so references stay valid."),
            ("Identity preserved", "Library rows are re-pointed rather than recreated, so cues, beat grids and play counts stay attached."),
        ),
        steps=(
            ("Back up", "This one moves real audio files. Take a full backup first."),
            ("Map your sources", "Run the scan and look at the source groups it found."),
            ("Pick a destination", "Choose the folder everything should live in, and check the capacity estimate."),
            ("Select and run", "Choose the source groups to pull in, run it with Serato closed, then reopen Serato and spot-check a few crates."),
        ),
        related=("missing-tracks", "backup", "rename"),
    ),
    Feature(
        slug="backup",
        name="Backup",
        nav="Backup",
        icon="history",
        tagline="Timestamped snapshots of your library, sized before you commit to them.",
        shot="shot-backup.webp",
        shot_title="Backup",
        shot_alt="The Backup workspace with full, incremental and single-crate modes and an estimated size and file count.",
        intro=(
            "EZLibrary snapshots any Serato file it is about to write, automatically. The Backup "
            "tab is the deliberate version of that: a full, self-contained copy you can take "
            "before a big change, or on a schedule you keep yourself.",
            "Backups land in a <code>SeratoBackups</code> folder, each in its own timestamped "
            "directory, as ordinary files you can browse in Finder.",
        ),
        does=(
            ("Three modes", "<strong>Full</strong> for everything, <strong>incremental</strong> for what changed since the last one, <strong>single crate</strong> for one night's music."),
            ("Estimate first", "The size and file count are shown before the backup starts, so a full backup never surprises you."),
            ("Genuinely incremental", "Tracks already captured in the previous backup are skipped instead of re-copied."),
            ("Tolerant of gaps", "A single-crate backup no longer aborts because one referenced file has been moved or deleted — it skips it and carries on."),
            ("Plain files", "No proprietary archive. It is a folder of your library and your music, restorable by hand if you ever need to."),
        ),
        steps=(
            ("Choose a mode", "Full for a real safety net; single crate when you just want tonight's set safe."),
            ("Check the estimate", "Confirm the size and count against the free space where the backup is going."),
            ("Run it", "The backup is written to a timestamped folder under <code>SeratoBackups</code>."),
        ),
        note="Run a full backup before your first duplicate cleanup or consolidation. Those are the "
             "two operations that delete or move real audio files.",
        related=("duplicates", "consolidation", "missing-tracks"),
    ),
    Feature(
        slug="rename",
        name="Rename From Tags",
        nav="Rename From Tags",
        icon="pencil",
        tagline="Consistent filenames across your whole library — and Serato still finds every one of them.",
        status="New in 1.0",
        status_class="badge badge-beta",
        intro=(
            "Renaming a file that Serato has already analysed is normally how you lose it. Serato "
            "keys its library on the path, so the renamed file comes back as a brand-new track and "
            "the original sits there as <em>cannot be located</em>, holding your cues and beat grid.",
            "EZLibrary renames the file and updates everything Serato reads in the same operation, "
            "so the track keeps its identity. You can do it one track at a time, or across a whole "
            "selection.",
        ),
        does=(
            ("Your naming scheme", "Set a template in Settings from <code>{artist}</code>, <code>{title}</code>, <code>{album}</code>, <code>{year}</code> and <code>{genre}</code>. Tokens with no value drop out along with their separators, so a missing year cannot leave a stray dash behind."),
            ("Bulk rename", "<strong>Rename Files From Tags</strong> in the Tracks &amp; Tags bulk bar renames the whole selection in a single pass."),
            ("Preview before anything moves", "A resizable list shows every rename in advance, plus a plain-language summary of what is being skipped and why."),
            ("Skips instead of guessing", "Tracks already named correctly, names that would collide with another selected track, destinations that are already taken, and tracks not found in the Serato library are all left alone."),
            ("Updates all four layers", "Serato's SQLite library, <code>database V2</code>, plain crates and smart crates are all rewritten together."),
            ("All or nothing", "If a track cannot be matched in Serato's library, the rename is rolled back and the file is put back under its original name."),
        ),
        steps=(
            ("Set your template", "Settings → filename format. The preview updates as you type."),
            ("Select the tracks", "In Tracks &amp; Tags, select what you want renamed. Scoping to one crate first is a good way to try it out."),
            ("Preview", "Click <em>Rename Files From Tags</em> and read the list, including the skips."),
            ("Apply", "With Serato closed, apply. Reopen Serato and the tracks are where they were, cues and all."),
        ),
        note="Smart crates were the last piece of this puzzle. A <code>.scrate</code> file keeps a "
             "materialised list of its member paths next to its rules, and one stale path in there "
             "was enough to make Serato re-import the old name as a second, missing entry.",
        related=("tracks-and-tags", "consolidation", "missing-tracks"),
    ),
    Feature(
        slug="cli",
        name="Command Line Tools",
        nav="Command Line",
        icon="terminal",
        tagline="The same engine, scriptable — for imports, bulk repair and anything you want to automate.",
        intro=(
            "<code>EZLibraryCLI</code> ships alongside the app and runs the same core code with the "
            "same safety rules: a backup before every write, atomic file replacement, and a refusal "
            "to run while Serato is open.",
            "It exists for the jobs that are painful in a GUI — importing a folder from a script, "
            "or repairing thousands of library entries in one pass.",
        ),
        does=(
            ("Scripted import", "Import files and folders with a chosen mode, destination and crate prefix, and wire it into whatever else you run."),
            ("Bulk location repair", "<code>repair-locations</code> re-points Serato's library at where files actually are, for a library knocked out of sync by an old move or consolidation."),
            ("Preview by default", "<code>repair-locations</code> shows you what it would change and writes nothing until you pass <code>--apply</code>."),
            ("Reports rather than guesses", "Anything it cannot match with confidence is listed as unresolved instead of being repaired on a hunch."),
        ),
        steps=(
            ("Import a folder", 'Move files into your library and file them under a dated crate prefix:<pre><code>swift run EZLibraryCLI \\\n  --mode move \\\n  --destination "$HOME/Music" \\\n  --crate-prefix "New Music" \\\n  -- ~/Downloads/incoming</code></pre>'),
            ("Preview a repair", "<pre><code>swift run EZLibraryCLI repair-locations \\\n  --search /Volumes/Music</code></pre>"),
            ("Apply it", "Re-run the same command with <code>--apply</code> once the preview looks right. Serato has to be closed."),
        ),
        note="Run <code>swift run EZLibraryCLI --help</code> for the full option list, including "
             "<code>--library-dir</code> for pointing at a specific <code>_Serato_</code> folder.",
        related=("add-music", "missing-tracks", "consolidation"),
    ),
]


# --------------------------------------------------------------------- markup


def header(prefix: str, current: str = "") -> str:
    def mark(page: str) -> str:
        return ' aria-current="page"' if page == current else ""

    return f"""<header class="site-header">
  <div class="wrap">
    <a class="brand" href="{prefix}"><img src="{prefix}assets/img/icon.png" alt=""> EZLibrary</a>
    <button class="nav-toggle" aria-expanded="false" aria-controls="site-nav">Menu</button>
    <nav class="nav" id="site-nav" aria-label="Main">
      <a href="{prefix}features/"{mark("features")}>Features</a>
      <a href="{prefix}roadmap/"{mark("roadmap")}>Roadmap</a>
      <a href="{prefix}support/"{mark("support")}>Support</a>
      <a href="{REPO}">GitHub</a>
      <a class="btn btn-sm btn-primary" href="{RELEASES}" data-download>Download</a>
    </nav>
  </div>
</header>"""


def footer(prefix: str) -> str:
    return f"""<footer class="site-footer">
  <div class="wrap">
    <div class="footer-grid">
      <div class="footer-about">
        <a class="brand" href="{prefix}"><img src="{prefix}assets/img/icon.png" alt=""> EZLibrary</a>
        <p>A free, open source macOS toolkit for DJs who want a cleaner, safer Serato library.</p>
      </div>
      <div>
        <h4>Product</h4>
        <ul>
          <li><a href="{prefix}features/">Features</a></li>
          <li><a href="{prefix}roadmap/">Roadmap</a></li>
          <li><a href="{RELEASES}" data-download>Download</a></li>
          <li><a href="{REPO}/blob/main/docs/CHANGELOG.md">Changelog</a></li>
        </ul>
      </div>
      <div>
        <h4>Help</h4>
        <ul>
          <li><a href="{prefix}support/">Support &amp; FAQ</a></li>
          <li><a href="{prefix}support/#how-to">How-to guides</a></li>
          <li><a href="{prefix}support/#contact">Contact</a></li>
          <li><a href="{REPO}/issues/new/choose">Report a bug</a></li>
        </ul>
      </div>
      <div>
        <h4>Project</h4>
        <ul>
          <li><a href="{REPO}">Source on GitHub</a></li>
          <li><a href="{REPO}/blob/main/CONTRIBUTING.md">Contributing</a></li>
          <li><a href="{REPO}/blob/main/SECURITY.md">Security policy</a></li>
          <li><a href="{REPO}/blob/main/LICENSE">License (GPLv3)</a></li>
        </ul>
      </div>
    </div>
    <div class="footer-bottom">
      <p class="disclaimer">
        EZLibrary is an independent, community-built utility. It is not affiliated with,
        endorsed by, or sponsored by Serato Audio Research. "Serato" is a trademark of its
        respective owner.
      </p>
      <p>© 2026 Tawaun Lucas · GPLv3</p>
    </div>
  </div>
</footer>"""


def head(title: str, description: str, prefix: str, canonical: str) -> str:
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>{title}</title>
<meta name="description" content="{description}">
<link rel="icon" href="{prefix}assets/img/icon.png">
<link rel="canonical" href="https://tawaunl.github.io/EZLibrary/{canonical}">
<link rel="stylesheet" href="{prefix}assets/css/site.css">
<meta property="og:type" content="website">
<meta property="og:title" content="{title}">
<meta property="og:description" content="{description}">
<meta property="og:image" content="https://tawaunl.github.io/EZLibrary/assets/img/icon.png">
</head>
<body>
<a class="skip-link" href="#main">Skip to content</a>"""


def sidebar(current: Feature) -> str:
    items = "\n".join(
        '          <li><a href="{slug}.html"{mark}>{nav}</a></li>'.format(
            slug=feature.slug,
            nav=feature.nav,
            mark=' aria-current="page"' if feature.slug == current.slug else "",
        )
        for feature in FEATURES
    )
    return f"""      <aside class="aside">
        <h4>All features</h4>
        <ul>
{items}
        </ul>
        <a class="btn btn-primary btn-sm" style="width:100%" href="{RELEASES}" data-download>Download EZLibrary</a>
      </aside>"""


def feature_page(feature: Feature) -> str:
    prefix = "../"
    parts = [
        head(
            f"{strip_tags(feature.name)} — EZLibrary",
            strip_tags(feature.tagline),
            prefix,
            f"features/{feature.slug}.html",
        ),
        header(prefix, "features"),
        '<main id="main">',
        f"""
<section class="page-hero">
  <div class="wrap">
    <p class="crumbs"><a href="{prefix}">Home</a><span>/</span><a href="{prefix}features/">Features</a><span>/</span>{strip_tags(feature.name)}</p>
    <h1>{feature.name} <span class="{feature.status_class}">{feature.status}</span></h1>
    <p>{feature.tagline}</p>
  </div>
</section>

<section class="section">
  <div class="wrap">
    <div class="two-col">
      <div class="prose">""",
    ]

    for paragraph in feature.intro:
        parts.append(f"        <p>{paragraph}</p>")

    if feature.shot:
        parts.append(
            f"""
        <figure class="shot" style="margin:32px 0">
          <div class="shot-bar"><i></i><i></i><i></i><span>{feature.shot_title}</span></div>
          <img src="{prefix}assets/img/{feature.shot}" alt="{feature.shot_alt}" loading="lazy">
        </figure>"""
        )

    if feature.does:
        parts.append("\n        <h2>What it does</h2>\n        <ul class=\"ticks\">")
        for title, body in feature.does:
            parts.append(f"          <li><strong>{title}.</strong> {body}</li>")
        parts.append("        </ul>")

    if feature.steps:
        parts.append("\n        <h2>How to use it</h2>\n        <ol class=\"steps\">")
        for title, body in feature.steps:
            body_html = body if body.lstrip().startswith("<pre") else f"<p>{body}</p>"
            if "<pre" in body and not body.lstrip().startswith("<pre"):
                body_html = body
            parts.append(f"          <li>\n            <h3>{title}</h3>\n            {body_html}\n          </li>")
        parts.append("        </ol>")

    if feature.note:
        parts.append(f'\n        <div class="note"><p>{feature.note}</p></div>')

    if feature.related:
        lookup = {item.slug: item for item in FEATURES}
        cards = "\n".join(
            f"""          <a class="card" href="{lookup[slug].slug}.html">
            <h3>{lookup[slug].name}</h3>
            <p>{lookup[slug].blurb}</p>
          </a>"""
            for slug in feature.related
            if slug in lookup
        )
        parts.append(
            f"""
        <h2>Related</h2>
        <div class="grid grid-2">
{cards}
        </div>"""
        )

    parts.append("      </div>\n" + sidebar(feature) + "\n    </div>\n  </div>\n</section>")
    parts.append(cta_band())
    parts.append("</main>\n")
    parts.append(footer(prefix))
    parts.append(f'\n<script src="{prefix}assets/js/site.js"></script>\n</body>\n</html>\n')
    return "\n".join(parts)


def cta_band() -> str:
    return f"""
<section class="cta">
  <div class="wrap">
    <h2>Try it on your own library</h2>
    <p>Free and open source. Takes a backup before it touches anything.</p>
    <div class="btn-row center" style="margin-top:26px">
      <a class="btn btn-primary btn-lg" href="{RELEASES}" data-download>
        <svg width="19" height="19" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">
          <path d="M12 3v12M7 11l5 5 5-5M4 20h16"/>
        </svg>
        Download for macOS
      </a>
    </div>
    <p class="meta-line">v<span data-latest-version>1.0</span> · <span data-latest-size>8.2 MB</span> · macOS 13+ · Apple Silicon &amp; Intel</p>
  </div>
</section>"""


def features_index() -> str:
    prefix = "../"
    cards = "\n".join(
        f"""      <a class="card" href="{feature.slug}.html">
        <div class="card-icon">
          <svg width="21" height="21" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.9" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">{ICON.get(feature.icon, "")}</svg>
        </div>
        <h3>{feature.name}</h3>
        <p>{feature.blurb}</p>
      </a>"""
        for feature in FEATURES
    )

    return "\n".join(
        [
            head(
                "Features — EZLibrary",
                "Every workspace in EZLibrary: tag editing, duplicate detection, missing-track "
                "repair, crates, PlaylistMatch, imports, consolidation, backup and bulk renaming.",
                prefix,
                "features/",
            ),
            header(prefix, "features"),
            '<main id="main">',
            f"""
<section class="page-hero">
  <div class="wrap">
    <p class="crumbs"><a href="{prefix}">Home</a><span>/</span>Features</p>
    <h1>Everything EZLibrary does</h1>
    <p>Ten workspaces over one Serato library. Each one reads and writes the same files,
      takes a snapshot before it changes anything, and never guesses on your behalf.</p>
  </div>
</section>

<section class="section">
  <div class="wrap">
    <div class="grid grid-3">
{cards}
    </div>
  </div>
</section>

<section class="section section-alt">
  <div class="wrap wrap-narrow">
    <div class="section-head center">
      <span class="eyebrow">Across every feature</span>
      <h2>The rules that don't change</h2>
    </div>
    <ul class="ticks">
      <li><strong>A timestamped snapshot before every write</strong>, whether or not you asked for a backup.</li>
      <li><strong>Atomic writes</strong>, so an interrupted operation cannot leave a Serato file half-written.</li>
      <li><strong>Read-back verification</strong> after tag writes, with a rollback if what landed does not match.</li>
      <li><strong>Refuses to write while Serato is running</strong>, because Serato would overwrite the change on quit.</li>
      <li><strong>Nothing repaired silently</strong> — ambiguous cases are reported to you, not guessed at.</li>
      <li><strong>Cues, beat grids and play counts survive</strong> renames, moves and repairs.</li>
    </ul>
    <div class="btn-row" style="margin-top:26px">
      <a class="btn" href="{REPO}/blob/main/docs/SECURITY_AND_DATA_HANDLING.md">How this is implemented</a>
      <a class="btn" href="{prefix}roadmap/">What's coming next</a>
    </div>
  </div>
</section>""",
            cta_band(),
            "</main>\n",
            footer(prefix),
            f'\n<script src="{prefix}assets/js/site.js"></script>\n</body>\n</html>\n',
        ]
    )


def strip_tags(text: str) -> str:
    out, depth = [], 0
    for char in text:
        if char == "<":
            depth += 1
        elif char == ">":
            depth = max(0, depth - 1)
        elif depth == 0:
            out.append(char)
    return "".join(out).replace("&amp;", "&").replace('"', "&quot;")


def main() -> int:
    OUT.mkdir(parents=True, exist_ok=True)
    written = []

    (OUT / "index.html").write_text(features_index(), encoding="utf-8")
    written.append(OUT / "index.html")

    for feature in FEATURES:
        path = OUT / f"{feature.slug}.html"
        path.write_text(feature_page(feature), encoding="utf-8")
        written.append(path)

    for path in written:
        print(path.relative_to(ROOT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
