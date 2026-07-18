# EZLibrary GUI crash — investigation handoff (2026-06-30)

## Status: unresolved, paused mid-bisection

The app reliably crashes 4–90 seconds after launch whenever it's actually run
as a GUI app (window on screen). This is **not** a bug in `SeratoToolsCore`
or in the Phase 1 feature logic (CrateView / Missing Tracks) — those are all
verified correct via scratch-executable tests against the real library (see
`docs/ROADMAP.md`). This is purely a SwiftUI/AppKit UI-layer crash.

## The crash, precisely

Every single crash (9 captured so far, all with `EXC_BREAKPOINT`/`SIGTRAP`
at the identical address `0x192189640`) has this signature:

```
0  CoreFoundation   __exceptionPreprocess
1  libobjc.A.dylib  objc_exception_throw
2  Foundation       -[NSCalendarDate initWithCoder:]
3  AppKit           -[NSToolbar _insertNewItemWithItemIdentifier:atIndex:propertyListRepresentation:notifyFlags:]
4  SwiftUI          AppKitToolbarStrategy.updateLocations() [inlined update chain]
...
   AppKit           NSApplication run loop / display cycle
```

An `NSException` is thrown while AppKit tries to decode a persisted toolbar
item using the ancient `NSCalendarDate` class, inside SwiftUI's internal
`NavigationSplitView` toolbar bridge. AppKit's `_crashOnException:` then
terminates the process. Crash reports are saved at
`~/Library/Logs/DiagnosticReports/EZLibrary-*.ips` — 9 are there now,
useful for a fresh `grep`/parse pass.

Environment: macOS 26.5.1 (25F80), only Xcode Command Line Tools installed
(no full Xcode/`xcodebuild`), Swift 6.3.3, Package.swift targets
`.macOS(.v14)`.

## What's been ruled out (tried, did not fix it — identical crash signature persisted)

1. **Clearing app preferences** (`~/Library/Preferences/EZLibrary.plist`,
   `com.seratotools.app.plist`, which hold `NSSplitView Subview Frames`/
   `NSWindow Frame` autosave data) — no effect.
2. **Running as a properly-signed `.app` bundle** (via `Scripts/build-app.sh`,
   stable bundle id `com.seratotools.app`) instead of the raw
   `.build/debug/EZLibrary` executable — no effect, crashed identically.
3. **Disabling window restoration**: added
   `Sources/SeratoToolsApp/Views/WindowConfigurator.swift`, an
   `NSViewRepresentable` that sets `window.isRestorable = false`, wired in
   via `.background(WindowConfigurator())` in `SeratoToolsApp.swift`. No
   effect. **Currently still in the tree, uncommitted** — didn't help, kept
   only because it's harmless; feel free to rip it out if it stays useless.
4. **Hiding the window toolbar**: added `.toolbar(.hidden, for: .windowToolbar)`
   to `ContentView.swift`. No effect — crashed with the identical address
   even with the toolbar visually hidden. **Currently still in the tree,
   uncommitted.**

## What's been confirmed via isolation testing

Built throwaway minimal SwiftUI apps (outside this package, in scratchpad,
now deleted) to bisect:

- A **minimal 2-column `NavigationSplitView`** (just `List` + `Text`, zero
  app code) survived a full 2-minute soak test with **no crash**.
- A **minimal 3-column `NavigationSplitView` + `Table`** (20 synthetic rows,
  still zero app code, zero `ObservableObject`s) also survived 2 minutes
  with **no crash**.
- **This rules out**: `NavigationSplitView` itself, 3-column layout, and
  `Table` in isolation as the trigger. The bug needs something specific to
  *our* app.
- The **real app pointed at an empty/nonexistent library directory**
  (`SERATOTOOLS_LIBRARY_DIR=/tmp/nonexistent-empty-serato-dir`, so
  `reload()` throws immediately via `try?` and `tracks`/`crates` stay
  empty) **still crashed**, in ~4 seconds, identical signature.
- **This rules out**: real data volume (1343 tracks) or the timing of the
  async `.task { reload() }` doing real file I/O as the trigger. The crash
  happens even with zero data loaded. **This is the most useful finding —
  it means the bug is structural (something about our view composition,
  environment objects, or modifiers), not data-scale-related.**

## What hasn't been tried yet — where to pick up

Bisect **within the real app** by temporarily gutting pieces of
`Sources/SeratoToolsApp/Views/ContentView.swift` (and rebuilding via
`swift build && ./Scripts/build-app.sh`, then launching
`dist/EZLibrary.app/Contents/MacOS/EZLibrary` with
`SERATOTOOLS_LIBRARY_DIR` set to the empty path above — no need for real
data given the finding above) to find the minimal trigger. Candidates, in
suggested test order (each is present in the real app but absent from the
minimal repros that survived):

1. **The 4 injected `@EnvironmentObject`/`@ObservedObject` types**
   (`LibraryService`, `HiddenCrateStore`, `MissingTracksService`,
   `CrateHierarchyViewModel` ×2) — the minimal repro had zero
   `ObservableObject`s. Try a version of `ContentView` with the environment
   objects still injected but the body reduced to a static `Text`.
2. **`.searchable(text:)`** — used in `CrateTreeView.swift` and
   `TrackTableView.swift`, absent from the minimal repro. Try adding just
   `.searchable` to the minimal 3-column+Table repro.
3. **`OutlineGroup`/`DisclosureGroup`** (in `CrateTreeView.swift`) — untested
   in isolation.
4. **`ContentUnavailableView`** (in `CrateDetailView.swift`) — untested in
   isolation, macOS-14-only API, worth a quick check.
5. **The custom `Label(..., systemImage:)` sidebar rows with a
   `Hashable` enum tag** (`SidebarSection`) vs. the minimal repro's plain
   `Text` sidebar rows.

A `git stash`/temporary-edit loop against the real `ContentView.swift`,
rebuilding and soak-testing each variant for ~60–90s (crashes have taken
anywhere from 4s to 90s to appear, so give each variant at least 90s before
calling it clean) is the fastest way to close this out. Once found, the fix
is likely either (a) a targeted code change avoiding the specific
API/pattern, or (b) confirming it's a genuine SwiftUI/AppKit regression on
this macOS version worth filing as Apple Feedback, in which case a
different UI pattern (e.g. dropping down to `NSSplitViewController` via
`NSViewControllerRepresentable`, or a 2-column layout instead of 3) may be
the pragmatic workaround.

## Also worth trying if the above doesn't pin it down

- `log show --predicate 'process == "EZLibrary"' --last 5m` right after a
  fresh crash, for any warnings/errors beyond what's in the `.ips` file
  (the `.ips` only captures the final stack, not preceding log lines).
- The existing benign "reentrant operation in its NSTableView delegate"
  warning (seen on every launch, `List`/`Table`-related) may or may not be
  related — it's present on launches that eventually crash AND was present
  before this crash was first noticed, so treat as a separate, lower-priority
  lead unless the bisection above points back at `List`/`Table` selection
  handling.

## Current git state

- Last commit: `35b4bbd` "Add Phase 1 features: CrateView and Missing
  Tracks" (includes the new `TrackTableView.swift` library table and the
  `CrateDetailView.swift` update to use it — this is the UI work that
  preceded noticing the crash, though isolation testing above shows `Table`
  alone isn't the cause).
- **Uncommitted, not yet proven useful**: `WindowConfigurator.swift` (new
  file) and the `.toolbar(.hidden, for: .windowToolbar)` line in
  `ContentView.swift`, plus the `.background(WindowConfigurator())` line in
  `SeratoToolsApp.swift`. Leave them for now (harmless) or revert them —
  your call — but don't treat them as "the fix," they aren't.
- Everything else (Phase 0 + Phase 1 core logic, tests, fixtures) is
  committed and verified working correctly via non-GUI scratch executables.

## Reminder: environment constraints (unrelated to this bug, but relevant)

- Only Command Line Tools installed, no full Xcode — `swift build`/`swift
  run` work fine; `swift test` compiles but discovers 0 tests (confirmed
  Phase 0 limitation). Use throwaway scratch SwiftPM packages (see pattern
  used throughout `docs/ROADMAP.md`'s verification sections) for anything
  needing to actually execute and assert.
- The real, populated Serato library for testing lives at
  `/Volumes/Crucial X10/_Serato_` (1343 tracks) — `~/Music/_Serato_` is
  empty. `SERATOTOOLS_LIBRARY_DIR` env var (DEBUG-only override in
  `SeratoToolsApp.swift`) points the app at any path for testing.
