# LaunchpadNative

A native, fully OSS macOS Launchpad replacement for macOS 26+ on Apple Silicon.
Runs as a resident `LSUIElement` utility (no Dock icon) and reproduces and
extends Classic Launchpad: paged/vertical app grid, folders, search, global
trigger gestures (hotkey, hot corner, F4, trackpad pinch), a window browser,
and a guided complete-uninstall tool for other apps.

No App Store distribution, no signing/notarization/DMG/installer, no paid
tiers — source only, built and run from this repository.

## Status

Phase 0 (bootstrap) and Phase 1 (Private API contract freeze — see
`ReverseEngineering/Contracts/`) are done. Phase 2 (application catalog +
persistence) is implemented: `Catalog` scans `/Applications`,
`/System/Applications`, and `~/Applications` into stable-identity
`ApplicationRecord`s (code-signing team ID via the public `Security`
framework, not LaunchServices SPI), watches them incrementally via FSEvents,
and caches icons off the main actor; `Persistence` stores the versioned
`LayoutDocument` with atomic writes and a last-known-good backup. Verified on
a real machine: 99 real apps scanned via the resident host and via
`Tools/CatalogProbe`.

Phase 3 (launcher surface) is implemented: a borderless overlay panel joins
every Space and floats over fullscreen apps (public `NSWindow.CollectionBehavior`,
no private SkyLight window-level poking needed here), backed by
`NSGlassEffectView` (falling back to `NSVisualEffectView` on Reduce
Transparency or pre-26), with search, keyboard navigation, real app launch
via `NSWorkspace`, and all the spec's close conditions (Escape, background
click, losing key status, same-trigger toggle). The grid itself is a plain
`NSCollectionViewFlowLayout` for now — the custom paged/vertical layout,
folders, and drag-and-drop are Phase 4. Verified live: built the release
`.app`, launched it with `LAUNCHPAD_DEBUG_AUTOSHOW=1` (temporary — permanent
global triggers are Phase 5), and screenshotted the real overlay over the
desktop with search focused and icons loading in.

Phase 4 (grid, pages, folders, import) is implemented: `Grid` adds
`PagedGridLayout` (a real custom `NSCollectionViewLayout`, not
`NSCollectionViewFlowLayout` and never SwiftUI `LazyVGrid`), `GridModel`
(reconciles pages/folders against catalog changes, handles reorder/folder
create-join-dissolve/rename), a capability-driven context menu, and a
read-only importer for the pre-26 Classic Launchpad SQLite DB. Verified live:
cleared this app's own layout store and launched fresh — the real Classic
Launchpad DB on this machine imported correctly, with folders ("その他"/10
items, "ゲーム"/5 items) and app ordering matching the legacy data exactly
(screenshotted). A real bug was caught and fixed during this verification:
the catalog-reconcile step needs to run *after* the one-time legacy import,
not before, or the import silently no-ops. Dragging an app onto the real
Dock and clicking to open a folder were not live-driven in this sandboxed
session (no Accessibility permission for GUI-scripting tools) — covered
instead by 33 passing unit tests and code review of the standard
NSCollectionView drag-and-drop API used.

Phase 5 (global triggers) is implemented: `Triggers` adds a system-wide
hotkey (Carbon `RegisterEventHotKey`), event-driven hot corners (`NSEvent`
global mouse-moved monitor, not a polling timer), F4/Launch-Panel key capture
(`CGEventTap` at `.cghidEventTap`), and a raw multitouch thumb+3-finger pinch
recognizer built on the `Finger` struct verified by live hardware capture
(`Tools/MultitouchProbe`). `TriggerCoordinator` applies all four
independently, so one failing never takes another down. Verified live on
this machine (release build, `LAUNCHPAD_DEBUG_ALL_TRIGGERS=1` temporarily
forces settings on until Phase 6's Settings UI exists): F4 correctly failed
with a clear diagnostic (this app bundle lacks Input Monitoring permission,
as Phase 1 predicted), and the multitouch trigger activated and toggled the
launcher open from a real physical pinch gesture with no explicit `show()`
call in the code path.

**Post-Phase-5 hands-on fixes:** real device usage surfaced several concrete
bugs beyond the phases above, all fixed and verified live:
- `didSelectItemsAt` was an empty placeholder — clicking a grid icon never
  actually launched anything. Fixed to launch on click, matching real
  Launchpad.
- Paging was originally a wide scroll strip with a computed x-offset; live
  testing repeatedly found the page never visibly changed despite the scroll
  code running correctly. Replaced with a single-section-per-page data
  source swap (`GridViewController`/`PagedGridLayout`), which is now
  reliable, plus a 2-finger trackpad swipe (`GridCollectionView.scrollWheel`)
  and prev/next buttons (`PageControlView`) — the buttons previously dimmed
  to near-invisibility at 0.3 alpha on the last page, now always fully
  visible.
- `NSGlassEffectView.contentView` (used to host the launcher's interactive
  content) turned out not to reliably forward mouse events to its children,
  per Apple's own "z-order not guaranteed" caveat — clicks/buttons stopped
  working. Fixed by making the glass view a plain decorative sibling behind
  the real content instead of its container.
- The launcher's visibility was tracked with a separately-maintained `Bool`
  that drifted from the window's real state (the outside-click dismiss
  monitor kept seeing a stale `false` while the window was still visible).
  Fixed to read `window.isVisible` directly.
- The multitouch gesture went 4-finger → 2-finger → back to 4-finger with
  real bidirectional semantics (pinch closed opens, spread apart closes,
  matching Classic Launchpad) after 2-finger was found to collide with
  system pinch-to-zoom.
- `IconCache` was an `actor`, serializing every icon fetch onto one
  executor — cold-start icon loading for ~35 visible cells summed rather
  than overlapped. Rewritten as a concurrent-queue-backed class (lock only
  around the shared memory dictionary) with PNG instead of TIFF caching and
  a fire-and-forget disk write; confirmed via log timestamps that icon
  fetches now genuinely overlap across threads, and all icons render within
  ~2.5s of a cold launch (screenshotted) instead of visibly trickling in.
- `multitouchGestureEnabled` defaulted to `false`, and there was no Settings
  UI yet for a user to turn it on themselves — F4 needs Input Monitoring
  permission this app bundle doesn't have, so with multitouch off there was
  no working trigger at all outside a debug env var only the developer could
  set. This is why "the gesture doesn't open it" kept recurring even after
  the recognizer itself was verified correct. Default changed to `true`.
- A grid cell's clickable bounding box (NSCollectionView's default) was far
  larger than its rendered icon+label, so clicking what looked like empty
  space between icons still selected/launched something. Fixed via
  `GridCellItem.contentHitTestFrame` + a `GridCollectionView.mouseDown`
  override: only clicks actually within the icon+label area forward to
  normal selection; everything else routes to the background-dismiss path.

Phase 6 (customization) is implemented: `Settings` adds a SwiftUI window
(opened via a gear button in the launcher's search bar) with tabs for grid
density/icon size/layout mode, trigger enable toggles + hot corners +
gesture sensitivity, custom app-source folders (with include/exclude glob
support in `ApplicationSource`/`ApplicationBundleReader`), and a hidden-apps
list with unhide. `GridModel` gained real hide/unhide, alias (display-name
override, never touches the bundle), and custom-source persistence —
previously the context menu's Rename/Hide items just logged instead of
doing anything.

Phase 7 (window browser) is implemented: `WindowBrowser` enumerates a given
app's real windows via the public `ScreenCaptureKit` (`SCShareableContent`),
captures per-window thumbnails via `SCScreenshotManager.captureImage`
(cached briefly, only for requested windows — never a background sweep),
and activates/closes/minimizes a specific window by matching it to its
`AXUIElement` (title+frame heuristic) and using the public Accessibility
API, layered under app-level `NSRunningApplication.activate()`. No private
SkyLight enumeration API was needed for any of this — confirmed by testing
`CGWindowListCopyWindowInfo`/`SCShareableContent` directly on this machine
before writing the wrapper, per this project's "verify before wrapping"
rule; SkyLight's `SLSCopySpacesForWindows` remains the one piece not
implemented (moving a window to a different Space), since it's the one
capability with no public equivalent. Wired into the grid's "Show Windows"
context menu item (previously a disabled stub). Verified live via
`Tools/WindowBrowserProbe`: enumerated Brave Browser's 2 real windows,
captured a real 1680x1050 thumbnail, and activation actually brought Brave
to the front (confirmed via `System Events` frontmost-process query) — with
Accessibility correctly reported as untrusted for this dev binary, falling
back to app-level-only activation exactly as designed.

Phase 8 (Complete Uninstall), part 1 — evidence, classification, fixture — is
implemented: `Uninstall` adds `OwnershipEvidenceCollector` (reads
Application Support/Caches/Preferences, user/system LaunchAgents and
LaunchDaemons, `pkgutil` package receipts, and `NSExtension` declarations —
all read-only, no file is ever moved, deleted, or executed) and
`RemovalPlanner` (a pure classification function: `owned` / `sharedRisk` /
`unknown`, with system-protected apps rejected outright and root-owned or
`/Library`-domain items flagged as needing a Privileged Helper this phase
doesn't implement). `OperationReport`/`OperationReportStore` persist a
dry-run plan using the same atomic-write-plus-backup pattern as
`Persistence.LayoutStore`. A purpose-built fixture
(`Scripts/build-uninstall-fixture.sh` + `Tools/UninstallFixtureProbe`) proves
the real filesystem-reading code end-to-end without ever touching a real
installed app — including a real `sharedRisk` classification when a
same-code-signing-team sibling's data is nested inside another app's folder.
The Settings window gained a read-only "Uninstall" tab (color-coded
owned/shared-risk/unknown), reachable from the grid's "Uninstall…" context
menu item (previously a disabled stub). Phase 8 part 2 — real execution, non-privileged only — is implemented:
`RemovalExecutor` acts on exactly the slice of a plan this phase considers
safe (`owned` items that don't need a Privileged Helper) and refuses
everything else outright, even if it somehow reached the function, with an
explanatory `succeeded: false` outcome rather than silently skipping it.
Every removal is `FileManager.trashItem` (moved to `~/.Trash`, never
`removeItem`), the target app is terminated first via
`NSRunningApplication` if it's running, and a user LaunchAgent is
`launchctl bootout`'d (a public CLI tool, not a private API) before its
plist is trashed. The Settings Uninstall tab gained a "Move Owned Items to
Trash…" button gated behind an `NSAlert` confirmation listing the exact
paths — shared-risk/unknown/privileged-helper items are never included, on
purpose. Verified live end-to-end against the fixture (not a real app):
`Tools/UninstallFixtureProbe --execute` actually trashed the fixture's
owned Caches folder and LaunchAgent plist (both recoverable in
`~/.Trash`, confirmed with `ls`) while correctly refusing to touch the
sharedRisk Application Support folder that nests the sibling fixture's own
data. **Privileged Helper removal, system extension deactivation, and
package receipt removal remain unimplemented.**

Phase 8 part 3 — broader related-file detection — is implemented:
`OwnershipEvidenceCollector` now also checks `~/Library/Containers`
(sandboxed app container), `~/Library/Saved Application State`,
`~/Library/WebKit`, `~/Library/HTTPStorages`, `~/Library/Cookies`,
`~/Library/Logs`, `~/Library/Application Scripts`,
`~/Library/Preferences/ByHost` (per-host prefs, matched by filename
prefix), and `~/Library/Group Containers` — every one of them still strictly
under the user's own home directory, so none of this needed a Privileged
Helper or changed the non-privileged execution scope from part 2. Group
Containers get a dedicated rule in `RemovalPlanner`: since they're shared
*by design* across every app in the same App Group, a Group Container
match is always classified `sharedRisk`, never `owned`, regardless of
whether a same-team sibling is even currently installed — deliberately
more conservative than the ordinary sibling-nesting check used for
everything else. (Crash reports under `~/Library/Logs/DiagnosticReports`
were deliberately left out — their filenames aren't reliably keyed by
bundle identifier, so matching on them risks false positives.) Verified
live: the fixture script now also creates a Container, a Saved Application
State folder, and a Group Container, and `UninstallFixtureProbe --execute`
confirmed the first two get trashed as `owned` while the Group Container
is correctly left untouched.

Phase 8 part 4 — Privileged Helper feasibility — is **resolved: not
viable**, and this concludes Phase 8's active work. `SMAppService.daemon(plistName:).register()`
was tested live against a real ad-hoc-signed copy of this app (no other
signing option exists without a paid Apple Developer Program membership)
carrying a deliberately inert daemon payload (writes one log line to
`/tmp`, touches nothing else). It failed immediately with
`SMAppServiceErrorDomain Code=1 "Operation not permitted"` — confirmed via
`codesign -dv` that the bundle's `TeamIdentifier` is `not set` (ad-hoc
signatures have none), and confirmed via `launchctl print system/...` and
the log file's absence that the daemon never registered or ran. Full
result in `ReverseEngineering/Contracts/privileged-helper.md`. Root-owned
removal (`/Library`-domain LaunchAgents/Daemons, package receipts) is
therefore a **permanent** limitation of this project's unsigned/Git-only
distribution model, not a "not yet implemented" gap — `RemovalExecutor`
already refuses those items with an explanation, and the Uninstall tab
directs the user to remove them manually.

Phase 9 (Performance, Accessibility, Reliability) and Phase 10 (OSS
Repository Finalization) are implemented, scoped to what's actually
verifiable without Instruments' GUI or an interactive VoiceOver session
(this project's sandboxed dev environment has no Accessibility permission
to drive either). Full measurements, methodology, and honestly-disclosed
gaps are in [`Diagnostics/Performance.md`](Diagnostics/Performance.md) —
warm-open latency, search-filter timing at the 1,000-app target size, idle
CPU, leak analysis, and a live crash-recovery test all passed their targets.
Accessibility labels were added to every previously-unlabeled interactive
control; Reduce Transparency/Increase Contrast were already handled and
Reduce Motion has nothing to gate (no custom animation exists). For Phase
10: confirmed (via `find` + `git log`) that no prohibited distribution
artifact exists anywhere in this repo or its history, added
`CONTRIBUTING.md`/`SECURITY.md`/issue templates, and verified a genuinely
fresh `git clone` into a scratch directory builds and passes all 80 tests
with no dependency on this machine's existing build cache.

**Trigger discoverability and Liquid Glass redesign** are implemented,
following real hands-on feedback that the only working trigger (the
4-finger pinch) wasn't discoverable and that the visual design didn't
commit fully to macOS's own Liquid Glass material. Fixes:
- `TriggerSettings.default` now enables the bottom-right hot corner
  out of the box (classic Launchpad's own convention), alongside the
  existing multitouch default.
- The Settings Triggers tab gained a real hotkey recorder
  (`HotkeyRecorderView` — click, press a combo, it's captured and
  converted to the Carbon modifier bits `GlobalHotkeyTrigger` actually
  needs) and an inline "F4 needs Input Monitoring permission" hint with a
  button that opens System Settings' Privacy pane directly, so a
  non-working F4 toggle no longer looks like a silent bug.
- Double-clicking the `.app` in Finder — the single most natural thing a
  first-time user tries — now actually shows the launcher once the
  catalog is ready, instead of doing nothing visible at all (this app has
  no Dock icon by design). `applicationShouldHandleReopen` brings it back
  the same way clicking a normal app's Dock icon would.
- The search field, settings button, and page-control chevrons/dots are
  now each their own small piece of floating Liquid Glass (decorative
  `NSGlassEffectView` siblings behind the real controls, never containers
  for them — same hit-testing rule established in Phase 3/5), rather than
  bare controls sitting directly on the one full-screen background glass.
  Grid cell selection changed from a flat system-accent block to a soft
  translucent highlight with a thin bright edge, closer to how Liquid
  Glass surfaces themselves indicate selection. `NSGlassEffectContainerView`
  (confirmed present in the SDK, Tier 1) was evaluated but not adopted —
  merging the background with the small floating capsules into one
  container would mean either giving up the sibling-not-container
  hit-testing pattern or a much larger restructuring for a benefit (shared
  blur sampling) that isn't visually load-bearing at this UI's scale.

**Custom app icon and open/close/page animations** are implemented,
following a request for both. The real Apple Launchpad icon doesn't exist
anywhere to use — modern macOS folded Launchpad into the Dock and doesn't
ship it as a separate `.app` with its own icon asset (confirmed by
inspecting `Dock.app`'s `Assets.car` directly on this machine), and this
project won't bundle Apple's copyrighted artwork into a publicly-cloned
OSS repo regardless. `Tools/IconGenerator` draws an original squircle
gradient tile with a 3x3 grid of colorful rounded squares (the "apps in a
grid" concept, no Apple pixels involved) at every required resolution via
Core Graphics, assembled into `Resources/AppIcon.icns` with `iconutil`;
`Scripts/build-app.sh` now copies it into the bundle and touches the
installed copy so LaunchServices picks up the new icon. Opening/closing
the launcher now fades and scales in/out (`NSAnimationContext` + a
`CASpringAnimation` built from apple-design's damping-ratio/response
parameters, critically damped since neither transition carries gesture
momentum to earn a bounce) instead of appearing/disappearing instantly,
and is interruption-safe (a generation counter means a same-trigger reopen
mid-close-animation can't have the window yanked back out from under it
by a stale completion handler). Page changes now crossfade around the
existing (deliberately-kept) data-source-swap reload instead of hard-
cutting. Live-verified: the release build launches with the new icon in
`~/Applications`, shows the animated entrance with no errors in
`log stream`, and a screenshot confirms the glass search
capsule/settings chip/page-control pill all render correctly together.

**Cell-reuse icon corruption and gesture/system conflict fixes** are
implemented, from user-reported bugs: changing the icon size and then
searching made some app icons vanish or show the wrong app. Root cause:
`NSCollectionView` recycles cell instances across `reloadData()` calls
(which fire on every grid-settings Apply and every search keystroke), and
`GridCellItem`/`AppIconCollectionViewItem`'s async icon fetch had no check
that the cell still represented the same record by the time the fetch
completed — a fast burst of reloads could apply a stale (or blank) icon
onto a cell already recycled for a different app. Fixed with a cell-reuse
guard (`currentRequestKey`, set synchronously on configure, checked before
an async fetch's result is applied) across all three call sites
(`GridViewController`, `FolderContentsViewController`,
`LauncherViewController`). Separately, the 4-finger pinch/spread gesture
(previously default-on) was confirmed to collide with macOS's own default
trackpad gesture assignment for Launchpad/Mission Control — both this
app's raw `MultitouchSupport` listener and the system's own handler react
to the same physical gesture, which read as "barely usable." Default
flipped back to off (the bottom-right hot corner and a user-recordable
hotkey are enough of a discoverable default without it), and the Settings
Triggers tab now shows a standing warning with a button to open Trackpad
system settings whenever the gesture is turned on.

**Grid icon disappearance — actual root cause found and fixed.** The
cell-reuse guard above did not resolve the user's repeated report that
some grid icons still vanished. Direct inspection of the user's real
`~/Library/Application Support/com.launchpadnative.app/layout.json`
found the actual cause: `GridModel.capacityPerPage` (`columns * rows`)
was only consulted when *appending* new items in `reconcile()`, never
used to rebalance already-persisted `pages` when `gridSettings` shrank.
The user's document had `gridSettings` at 6x3 (capacity 18) but pages
of 34/35/11 items, left over from an earlier 7x5 (capacity 35) setting.
`PagedGridLayout` places item N at `row = N / columns`, so anything
past the new row count renders below the visible page bounds and is
simply never drawn. Fixed with `GridModel.reflowPagesToCurrentCapacity()`,
which regroups all items into chunks of exactly `capacityPerPage`
(preserving order), wired into both `updateGridSettings(_:)` (future
changes) and `loadDocument()` (self-heals documents already corrupted
before this fix existed). Live-verified against the user's real
corrupted document: pages went from [34, 35, 11] to [18, 18, 18, 18, 8]
(80 items preserved throughout, none lost or duplicated) after running
the fixed build once. Two new `GridModelTests` cover this; full suite
is 82 tests with 1 pre-existing unrelated flaky perf-timing failure.

**Search results ignored the configured icon size.** User report: typing
in the search field made "the app's size break." Root cause:
`AppIconCollectionViewItem` (the search-results cell) hardcoded a 64pt
icon and `NSCollectionViewFlowLayout.itemSize` was a fixed `96x110`,
regardless of `GridSettings.iconSize`. First fix pass used
`gridSettings.iconSize` directly, but that's incomplete: the persistent
grid (`GridViewController`) doesn't render icons at that raw setting
either — it treats it only as a *ceiling* on a proportional,
cell-size-derived value, so the grid's actual on-screen icon size can be
noticeably larger than the setting (confirmed on the user's real 6x3
grid with `iconSize` 160 — the rendered size exceeds that). Search still
didn't visually match after the first fix for exactly this reason. Fixed
properly by extracting that formula into a public
`GridViewController.currentIconSize`, and having
`LauncherViewController` read that instead of the raw setting for both
`AppIconCollectionViewItem` sizing and `searchResultsLayout.itemSize` —
search results now always match whatever the grid is actually rendering,
by construction, regardless of how that formula changes in the future.

A third report followed ("レイアウトも合わない" — the layout doesn't
match either): fixing icon size alone wasn't enough, because
`searchResultsLayout` also used its own hardcoded cell size (before the
icon-size fix) and always-constant spacing/margins (24pt gaps, 48pt
edges) independent of `GridSettings`, so typing a query swapped in a
visibly different grid — different column count, gaps, and edges — not
just smaller icons. Fixed by adding `GridViewController.currentCellSize`
(the grid's real per-slot size) and having `LauncherViewController`
apply that as `searchResultsLayout.itemSize`, plus reading
`GridSettings.horizontalSpacing`/`verticalSpacing`/`pageMargins`
directly for `minimumInteritemSpacing`/`minimumLineSpacing`/
`sectionInset`, recomputed whenever the grid reloads or a query changes.
Both views share one full-width surface with matching left/right
margins and the identical top offset from the search bar, so the same
cell size + spacing + margins naturally produces the same column count
— the flat search list now reads as *the same grid, filtered*, not a
separate one. Full suite: 82/82 pass.

Note: this session's Terminal has no Accessibility/GUI-scripting
permission, so none of these three search-related fixes could be
interactively verified by typing into the search field and
screenshotting the result — verification for all three was build +
test + `log stream` evidence only. If anything still looks off, a
screenshot or a precise description of the mismatch would help.

The user then provided actual screenshots (empty grid vs. a live "a"
search), which is what finally made the real remaining defect visible:
`AppIconCollectionViewItem`'s selected-state highlight still drew the
flat system `selectedContentBackgroundColor` (plain blue) instead of
the soft glass highlight (`GridCellItem.applySelection`'s translucent
white fill + thin border) — a leftover from when the grid's own
selection style was refined (that round only touched `GridCellItem`,
never the search cell). This went unnoticed while the search cell's
slot was a small fixed size; once the layout-matching fix above made
search cells size to the grid's real (often much larger) per-cell size,
that same flat blue filled a correspondingly large rectangle and read
as a jarring, out-of-place block next to the rest of the glass UI.
Fixed by giving `AppIconCollectionViewItem` its own `applySelection`
mirroring `GridCellItem`'s exactly. (The page-control dots visible at
the bottom of the search screenshot were confirmed by the user to be
an unrelated non-issue, not a bug.)

Interactively verifying any of this had been blocked by the same wall
each round: no Accessibility/GUI-scripting permission in this session's
Terminal, so the search field couldn't be typed into and the result
couldn't be screenshotted first-hand. Two things changed that: (1) a
debug-only hook, `LAUNCHPAD_DEBUG_SEARCH_QUERY` (env var, wired in
`AppDelegate`, forwarded through `LauncherWindowController` and
`LauncherViewController.debugSetSearchQuery`), drives a real query into
the already-showing launcher without any input simulation — the same
pattern the codebase already used for `LAUNCHPAD_DEBUG_SHOW_UNINSTALL`;
(2) the user ran it themselves (`LAUNCHPAD_DEBUG_SEARCH_QUERY=a open -a
...`) and sent back real screenshots, which is what finally made the
actual remaining defect visible and confirmable: the selection
highlight (both `GridCellItem` and `AppIconCollectionViewItem`) painted
its background on the *entire* collection-view cell — sized to the
grid's real per-slot size, which at this user's settings (6x3 grid,
160pt icons) is roughly 290x285pt — not just the icon+label. A selected
item's highlight was therefore a large, mostly-empty rectangle around a
much smaller icon, which read as obviously broken regardless of its
color ("これどう見てもおかしい"). Fixed in both cell types by moving the
highlight to a dedicated `highlightView` sized to hug the icon (top:
icon top -8, bottom: label bottom +8, leading/trailing: icon
leading/trailing ∓16) instead of filling the cell. Full suite: 82/82
pass.

**Localization infrastructure (English + Japanese)** — user requested
support for the ~40 languages macOS ships with; scoped down to building
the infrastructure plus English/Japanese now, with the remaining
languages to follow. Added a new `Localization` SPM target
(`Sources/Localization/`) exposing an `L10n` namespace of static
accessors (`L10n.searchPlaceholder`, `L10n.columnsLabel(_:)`, etc.) that
every other target (`Grid`, `Launcher`, `Settings`) now calls instead of
hardcoding English string literals — roughly 70 user-facing strings
across menus, Settings tabs, alerts, and accessibility labels were
converted. **A real SwiftPM gap surfaced during this work and is worth
recording**: a `.xcstrings` String Catalog declared via
`resources: [.process("Resources")]` builds and copies fine under
`swift build`, but the command-line SwiftPM build system does **not**
compile it into per-language lookup tables the way Xcode's IDE build
system does — the raw JSON file just gets copied into the resource
bundle as-is, so every lookup silently fell through to the English
default regardless of the system language, confirmed by directly
inspecting the built bundle's contents (no `en.lproj`/`ja.lproj`
anywhere) and by a temporary diagnostic log showing `apply=Apply` even
under `-AppleLanguages '(ja)'`. Since this project has no Xcode project
and is only ever built via `swift build`, switched from `.xcstrings` to
classic `en.lproj/Localizable.strings` + `ja.lproj/Localizable.strings`
files, which SwiftPM's command-line build has always compiled/copied
correctly. `L10n` reads them via `Bundle.localizedString(forKey:value:table:)`
with explicit keys (not the newer string-interpolation-based key
auto-generation, which would have made hand-authoring the catalog's
keys error-prone). Also required adding `defaultLocalization: "en"` to
`Package.swift` (missing before; SwiftPM needs it to treat `.lproj`
resources as localized at all) and `CFBundleDevelopmentRegion`/
`CFBundleLocalizations` in `Resources/Info.plist`. Because
`Bundle.module`'s generated accessor checks `Bundle.main.bundleURL`
(the `.app` root) before falling back to an absolute build-directory
path — neither of which is `Contents/Resources/`, where a hand-assembled
`.app` actually needs it — added `LocalizationBundle.swift`, which
checks `Bundle.main.resourceURL` first; `Scripts/build-app.sh` copies
`LaunchpadNative_Localization.bundle` into `Contents/Resources/` the
same way it already does for `AppIcon.icns`. Verified end-to-end: built
release, launched the installed `.app`'s binary directly with
`-AppleLanguages '(ja)'` and `-AppleLanguages '(en)'` in turn while a
temporary diagnostic log line (removed once confirmed) printed resolved
`L10n` strings — Japanese launch showed `apply=適用 search=検索`,
English showed `apply=Apply search=Search`, both with
`Bundle.main.preferredLocalizations` matching. Full suite: 82/82 pass.

**Search results now use the same click hit-test guard as the grid, and
the search field's text position is explicit.** The layout-matching
round sized search-result cells to the grid's real (often much larger)
per-cell size, but `AppIconCollectionViewItem` had no equivalent to
`GridCellItem.contentHitTestFrame` and `searchResultsCollectionView` was
a plain `NSCollectionView` with no `GridCollectionView`-style
background-click guard — meaning clicking the empty margin around a
search result icon could still select/launch it. Added
`AppIconCollectionViewItem.contentHitTestFrame` and a new
`SearchResultsCollectionView` (mirroring `GridCollectionView`'s
`mouseDown` guard, 10pt margin around the content frame, background
clicks routed to `onDidCancel` — same dismiss behavior as the grid's
own background click). Separately, `SearchFieldCell` (a small
`NSTextFieldCell` override of `drawingRect(forBounds:)`) now explicitly
centers the search field's text — both the placeholder and any typed
text go through this one code path, replacing implicit Auto-Layout-
frame-only centering that showed a small vertical offset in a
screenshot the user sent ("検索欄の文字が少しズレてる"). Full suite:
82/82 pass; verified via build/test/log evidence and the existing
`LAUNCHPAD_DEBUG_SEARCH_QUERY` hook (still error-free with the new
hit-test guard active) — visual confirmation of the exact pixel
alignment still needs the user's own screenshot, same constraint as
every other search-view visual fix this round.

**Jiggle mode, smoother page transitions, and mouse-wheel paging** —
the remaining three items from the same user request. (1) Dragging any
grid item now makes every visible icon wobble, matching real iOS/macOS
Launchpad's rearrange-mode convention: `GridViewController` implements
`NSCollectionViewDelegate`'s `draggingSession(_:willBeginAt:forItemsAt:)`/
`draggingSession(_:endedAt:dragOperation:)` (the latter fires on both a
completed drop and a cancelled drag, so one method covers both), adding/
removing a `CAKeyframeAnimation` on `transform.rotation.z` for every
`collectionView.visibleItems()`, with a randomized `beginTime` per cell
so they wobble slightly out of phase with each other rather than in
lockstep. Scoped to just the duration of one drag — this project has no
"done editing" affordance (no delete badges, no exit button) for a
persistent post-drag edit mode the way real Launchpad has, so the
wobble doesn't outlive the drag it started with. (2) Page transitions
(`jumpToPage`) now add a small directional slide (`transform.translation.x`,
via a `CASpringAnimation`, damping 1.0/no bounce since this is still a
discrete jump, not a continuously-tracked gesture) alongside the
existing crossfade — a jump to a later page slides content out left and
the new page in from the right, mirrored going back, instead of the
fade alone just cutting in place. The spring conversion math is a small
local duplicate of `LauncherWindowController`'s (`Grid` sits below
`Launcher` in the dependency graph, so that helper can't be imported
here). (3) `GridCollectionView.scrollWheel` now also recognizes a plain,
non-Apple mouse's discrete wheel tick (no `NSEvent.Phase` at all,
`hasPreciseScrollingDeltas == false` — previously swallowed entirely
alongside genuine non-events) and turns it into a page change, falling
back from `scrollingDeltaX` to `scrollingDeltaY` since most non-Apple
mice only have a vertical wheel; a 0.35s wall-clock cooldown replaces
the phase-driven latch the trackpad path uses, since discrete ticks
carry no phase to key a state machine off of. Full suite: 82/82 pass;
release build launches clean under `log stream`. **Disclosed
limitation, same as prior rounds**: this session has no Accessibility/
GUI-scripting permission, so none of drag-triggered wobble, the page
slide's actual feel, or physical-mouse-wheel paging could be tested
interactively here — verification was build/test/log only. These three
specifically need the user's own hands-on check (the mouse-wheel
direction mapping in particular is a judgment call that may need
flipping once tried with a real mouse).

**Follow-up round after hands-on feedback on the above**: the user tried
all of it live and reported several concrete problems, each traced to a
real, confirmed root cause (not guessed):

- *Wobble read as unsettling* — confirmed too fast/large at 0.035rad
  (~2°) over a 0.12s cycle; nearly halved the angle (0.016rad, ~0.9°)
  and roughly doubled the cycle (0.22s) so it reads as a calm sway
  instead of a frantic shake.
- *Both cold start and warm-trigger-to-visible felt slow.*
  `AppDelegate.applicationDidFinishLaunching` previously gated trigger
  registration (`applyCurrentTriggerSettings()`) and the first
  `show()` behind `scanner.performFullScan()` completing — meaning hot
  corners/gestures were silently inert immediately after a cold launch
  until the whole catalog scan finished (confirmed via code review: the
  gesture recognizer itself hops to the main actor and calls `show()`
  synchronously with no delay of its own — the wait was architectural,
  not in the recognizer). Moved both to run right after the persisted
  grid document loads instead; `updateRecords(_:)` fills in real catalog
  data moments later exactly the way the live FSEvents watcher's
  incremental updates already do. Separately, `LauncherWindowController.animateIn(window:)`
  faded the window's alpha over the *same* 0.45s as the scale spring, so
  the first ~100-150ms after any trigger fired were still nearly
  transparent — read as "nothing happened yet." Split them: alpha now
  fades in over 0.12s (the "did anything happen" signal, resolves
  almost immediately) while the scale spring keeps its full, slightly
  bouncy 0.45s settle running underneath (apple-design's response vs.
  behavior separation).
- *Changing rows in Settings changed the layout but not the app count
  per page* — user's own precise repro: "3→4 rows changes the cell
  height/empty space, but apps stay arranged for 3 rows, with the new
  row just empty." Root cause: `GridModel.updateGridSettings(_:)` only
  called `reflowPagesToCurrentCapacity()` when an existing page
  *exceeded* the new capacity — true for shrinking capacity, never true
  for growing it, so existing pages stayed grouped at the old, smaller
  capacity while only the visual layout (row count, cell size) updated.
  Now reflows unconditionally (a no-op in effect when capacity is
  unchanged or already correctly grouped, so this is safe). Added
  `increasingGridCapacityConsolidatesUnderfilledPages` test covering
  the previously-missing direction.
- *Gesture changed from 4-finger to 3-finger* per explicit request —
  `MultitouchGestureTrigger`/`PinchGestureRecognizer`'s
  `requiredContactCount` default changed 4→3 (existing tests, which
  hardcoded 4-contact fixtures, updated to 3-contact fixtures to match).
- *Continuous, drag-tracked page paging* ("iOS home-screen-like,
  reversible mid-drag") — user explicitly asked for this despite an
  earlier documented failure in this exact codebase (a prior
  "one continuous strip, scroll to x-offset" attempt using
  `NSScrollView`'s own scroll position "kept executing correctly per
  logs while visibly never changing the displayed page"). Deliberately
  not reattempting that approach — see the dedicated section below for
  the different, `CALayer`-transform-based approach used instead, which
  carries real, disclosed risk since it can't be verified interactively
  in this environment.

Full suite: 83/83 pass (82 prior + `increasingGridCapacityConsolidatesUnderfilledPages`).
Release build reinstalled to `~/Applications`; `log stream` confirmed
`Triggers applied: ...` now logs roughly a full second *before*
`Catalog ready: ...` on this machine's real app count (previously
gated behind it), and the launch is otherwise error-free.

**Continuous, drag-tracked page paging** — the largest and riskiest item
from the same follow-up round: real-time, reversible-mid-drag page
swiping (iOS home-screen-like), explicitly requested by the user despite
an earlier documented failure in this exact area (a prior
"one continuous strip, scroll to the page's x-offset" attempt using
`NSScrollView`'s own scroll position "kept executing correctly per logs
while visibly never changing the displayed page"). Deliberately did
*not* reattempt that approach. Instead: `GridCollectionView`'s trackpad
2-finger swipe handling now tracks continuously (new
`onSwipeBegan`/`onSwipeChanged`/`onSwipeEnded` callbacks, replacing the
old single-fire-past-a-threshold behavior for the trackpad path only —
the discrete mouse-wheel path from the prior round is unchanged, since
that hardware has no continuous position data to track).
`GridViewController` renders up to three static snapshots (previous/
current/next page) via a new throwaway offscreen `NSCollectionView` +
`PagedGridLayout` + a minimal standalone `SnapshotDataSource` (icons
sourced from `IconCache.cachedIconIfAvailable`, a new synchronous
best-effort peek added alongside the existing async `icon(for:)`, since
waiting on a disk/system icon fetch would delay the drag's very first
frame), overlays them in front of the live grid (hidden for the
duration), and slides the overlay via a direct `CALayer` transform —
the same technique this round's wobble and page-jump-slide animations
already use successfully, never touching `NSScrollView`'s scroll state
at all. Dragging past either end rubber-bands (apple-design's standard
resistance formula) instead of stopping hard or going arbitrarily far.
On release, distance *or* a fast-enough flick velocity commits to the
adjacent page (apple-design's momentum projection); a `CASpringAnimation`
(damping 1.0, velocity handed off per apple-design's relative-velocity
formula rather than hard-cut) settles the overlay before the real page
content swaps back in.

Given the direct precedent of "looked fine in logs, didn't actually
work," this got an extra verification step beyond build/test/log: a new
debug hook, `LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG=1`, drove
`beginPageDrag`/`updatePageDrag`/`endPageDrag` with synthetic input (a
fast flick) through the actual production code paths against this
machine's real 100-app catalog. `log stream` confirmed the state-machine
transition end-to-end with no crash: `debugSimulatePageDrag: starting at
page 0` → `debugSimulatePageDrag: ended at page 1 (was 0)`.

**This was not enough. On real hands-on use, this feature failed hard**:
the user hit a real trackpad interaction that left the grid completely
blank and unresponsive, requiring a force-quit to recover (confirmed via
screenshot), plus a related report that changing pages made everything
disappear. Root cause, found on re-reading the code: `GridCollectionView`
fired `onSwipeBegan` — which hides the live grid and swaps in the
snapshot overlay — from the very *first* `.changed` sample that looked
even slightly more horizontal than vertical, with no minimum-distance
gate at all. Any incidental trackpad motion (resting fingers, ambient
jitter) could trigger the full overlay takeover; combined with a settle-
path edge case that could leave `collectionView.isHidden` stuck `true`
forever (the only path back to `false` is `finishPageDrag`, scheduled via
`asyncAfter(deadline: .now() + spring.settlingDuration)`, which never
recovers if that duration is unexpected for a near-zero-distance spring),
this produced a real, permanently-stuck blank grid — and since every
page-change method (dots, arrows, gestures) all operate on the same now-
hidden `collectionView`, *any* attempt to change pages looked equally
broken afterward, matching the user's report exactly.

This is the **second** time a continuous/real-scroll-position approach
to paging has failed in this exact area on real hardware (see the
`NSScrollView`-based attempt above). Rather than attempt a third,
increasingly elaborate fix this session still can't verify
interactively, **the entire feature was reverted**: `GridCollectionView`
is back to the original threshold-based single-fire `onSwipePage`
(60pt, one jump per completed swipe), and `GridViewController`'s
`beginPageDrag`/`updatePageDrag`/`endPageDrag`/`finishPageDrag`/
`renderPageSnapshot`/`rubberBand`/`SnapshotDataSource`/the debug hook
were all removed. Page transitions are back to the crossfade+slide from
the earlier, safe round. If this operation-feel is still wanted in the
future, it should wait for a way to actually test a real trackpad
gesture interactively before trying again.

**Related regression found and fixed in the same investigation**: the
capacity-reflow fix above (`updateGridSettings` reflowing
unconditionally) turned out to have a real side effect — reflowing at an
*unchanged* capacity is not a no-op if the existing pages aren't already
tightly packed (e.g. a page the user intentionally left partially empty,
or gaps from manual drag-and-drop reordering). Since the fix reflowed on
*every* `updateGridSettings` call, applying any grid setting — including
ones with nothing to do with capacity, like icon size — silently
force-repacked every page tightly, destroying any such intentional
arrangement. Root-caused via a second user report
("行数の設定やページごとのアプリ数の数がおかしい"). Fixed by comparing
`capacityPerPage` before and after the settings change and only
reflowing when it actually differs — `reducingGridCapacityReflowsOversizedPages`/
`increasingGridCapacityConsolidatesUnderfilledPages` (capacity changes)
keep passing, and a new
`updatingSettingsWithoutCapacityChangePreservesNonCompactArrangement`
test covers the previously-broken case. Full suite: 84/84 pass.

**The real macOS Dock now stays visible over the launcher, like real
Launchpad.** `LauncherWindow`'s window level was `.popUpMenu` (101), well
above the real Dock's own window level
(`CGWindowLevelForKey(.dockWindow)`, a public CoreGraphics/Quartz Window
Services API, ~20), so the launcher always painted over the Dock,
hiding it — unlike real Launchpad, where the Dock stays on top. Now set
to `CGWindowLevelForKey(.dockWindow) - 1`: one level below the Dock, so
it renders in front, while the launcher still floats above regular and
fullscreen app windows (both far below the Dock's level). No change to
`collectionBehavior` — Space-joining and fullscreen participation are
independent of window level.

**Fixed a real, previously-undetected bug: dragging a grid icon (to
reorder, or onto another to create a folder) launched the app instead**,
confirmed via user report — and once fixed, this also makes the
already-implemented, already-unit-tested folder feature
(`GridModel.createOrJoinFolder`) actually usable over real mouse input
for the first time; it was never a missing feature, just blocked by this
bug. Root cause: `NSCollectionView` fires `didSelectItemsAt` synchronously
on mouse-down, before it's known whether the gesture continues into a
drag, and `GridViewController` launched immediately on every selection —
so starting to drag an icon always launched it first, regardless of
whether a reorder/folder-create drag followed. This went undetected all
session because unit tests only exercise `GridModel`'s data logic
(`moveItem`/`createOrJoinFolder`), not real AppKit mouse-event
disambiguation, and this session has no Accessibility permission to
test actual mouse drags interactively. Fixed by deferring the launch
decision to the next run-loop tick (`DispatchQueue.main.async`, not a
fixed timer) and checking a flag set by
`collectionView(_:draggingSession:willBeginAt:forItemsAt:)` (already
present for jiggle mode) — both fire synchronously within the same
mouseDown-tracking call, so by the time the deferred check runs, it
correctly reflects whether this gesture became a drag. Full suite:
84/84 pass. Disclosed limitation: this is exactly the class of bug that
can't be verified without a real mouse — build/test/log evidence only;
click-to-launch, drag-to-reorder, and drag-onto-another-icon-to-fold
all need the user's own hands-on check.

**Drag-tracked continuous page paging, reattempted a third time with a
structurally hardened design** (after explicit, informed user consent to
retry, given the two prior real-hardware failures above). This version
is deliberately different in the ways that matter for safety, not just in
degree:
- **The live `collectionView` is never hidden.** The previous failure's
  worst-case was a stuck-hidden grid with no way back; this version
  applies `layer.transform.translation.x` directly to the live
  `collectionView` itself (always visible, always the real content) and
  only snapshots the *one* adjacent page in the drag's direction (not
  both neighbors) as a single `NSImageView` tracking alongside it. Worst
  case if the snapshot fails to render: the neighbor image is missing,
  but the current page stays fully visible and interactive throughout.
- **A 15pt minimum-distance gate** on `GridCollectionView`'s `.changed`
  handler before `onSwipeBegan` fires at all — incidental trackpad
  contact/jitter no longer engages the drag-paging state machine.
- **A hard, fixed 1-second fallback timer**, independent of the spring's
  `settlingDuration` math, force-resets the drag state regardless of what
  the spring animation does — guarded by a generation counter so it can't
  double-fire against a normal completion.
- **State resets on every `show()`** and on background click
  (`resetDragStateIfNeeded()`), so even if something were left stuck, the
  very next time the launcher opens it starts clean.
Verified via the same debug-hook technique as before,
`LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG=commit|abort`, exercising both the
commit and the abort/spring-back paths through the real production code
against `log stream`: `debugSimulatePageDrag: starting at page 0,
commit=true` → `ended at page 1 (was 0)`, and `commit=false` → `ended at
page 0 (was 0)` — both with the process confirmed still running
afterward (`ps aux`, no crash). Full suite: 84/84 pass. **Disclosed
limitation, unchanged from every prior attempt in this area**: a debug
hook proves the state machine transitions correctly and doesn't crash —
it cannot prove the gesture *feels* right under a real finger. This is
the third attempt in an area with two prior real-world failures; the
user's own hands-on trackpad test is still required before considering
this closed.

**Settings window redesign: grouped sections and SF Symbols throughout**,
scoped down from a much larger LaunchOS-feature-parity request (the user
chose to redesign only the Settings UI visually this round, deferring the
larger feature checklist). Every tab (`Grid`/`Triggers`/`Sources`/
`Hidden`) now uses `Form { Section { ... } header: { Label(...) } }
.formStyle(.grouped)`, matching System Settings' own grouped-card
convention instead of a flat stack of controls. The grid layout-mode
picker uses `.pickerStyle(.radioGroup).horizontalRadioGroupLayout()` for
classic macOS-style radio buttons. Hot corner toggles get directional SF
Symbols (`arrow.up.left.square` etc.), the uninstall tab's ownership
badges are colored `Label`s (green `checkmark.circle.fill` = owned,
yellow `exclamationmark.triangle.fill` = shared risk, red
`questionmark.circle.fill` = unknown), Save/Trash buttons get icon
`Label`s (Trash uses `role: .destructive`), and a new
`ContentUnavailableLikeHint` centers the tab's empty states. The window
grew from 480×420 to 620×560 to fit the grouped layout comfortably. No
logic changed — `confirmAndExecuteRemoval()`, `classificationBadge(_:)`,
`addFolder()`, and all `L10n` string bindings are untouched; this is a
visual pass only. Full suite: 84/84 pass, release build succeeds.
**Disclosed limitation**: this session cannot reliably screenshot the
SwiftUI Settings window, so the actual visual result (does it look good,
does it match the reference design) needs the user's own look. Explicitly
deferred to a future round, per the user's own scoping choice: the
General/Interface/Apps/Advanced/About tab split, a Sort By dropdown, a
Reorganize button, a Hide Dock toggle, wallpaper/glass background-type
switching, a blur-wallpaper toggle, and the dozens of other items in the
full feature-parity spec (pinyin search, multiple sort modes,
backup/restore, multi-display strategies, a small-window mode, icon style
switching, etc.).

**Grid-paging fixes: vertical swipe support, and a confirmed page-drag
safety-net bug.** `GridCollectionView`'s continuous-swipe state machine
only ever tracked the horizontal axis; a vertical-dominant swipe was
silently dropped. It now tracks both axes and engages whichever one's
cumulative distance first clears the existing minimum-engage-distance
gate, feeding the same cumulative-delta pipeline `GridViewController`
already treats generically (down swipe = next page, up = previous — same
"negative delta → next" convention as horizontal; this mapping is an
unverified judgment call the user's own trackpad feel may want flipped).
Separately, a real bug was confirmed in `beginPageDrag`'s hard fallback
timer: it force-reset the entire drag state 1 second after the drag
*started*, not after it *ended* — so any deliberately slow drag (exactly
the "look at the next page before committing" use this feature exists
for) got silently cancelled mid-gesture, wiping the visible neighbor page
out from under the user's still-active fingers. Bumped to 30 seconds
(`dragSafetyNetTimeout`), which no realistic gesture will ever reach while
still guaranteeing eventual recovery from a genuinely stuck spring.
Verified via the existing `LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG=commit|abort`
hook — mechanics unaffected, no crash; real trackpad feel for both changes
still needs the user's own hands-on test.

**4/5-finger gesture picker, About tab, search-bar quick menu,
Settings-as-overlay, and a first-run onboarding wizard.** Several
requests bundled into one round, following a reference app's screenshots
for UI/UX inspiration only — see the note on reverse-engineering below.

- The multitouch gesture's finger count is now a Settings picker (4 or 5
  fingers), replacing the previous fixed 3-finger default — 3 was dropped
  as a selectable option per explicit user request.
  `PinchGestureRecognizer.updateRequiredContactCount(_:)` lets Settings
  switch this at runtime without recreating the recognizer/trigger. The
  existing conflict warning (this gesture can collide with macOS's own
  Launchpad/Mission Control trackpad assignment) is unchanged.
- A new About tab shows the app icon/name/version and the MIT license —
  deliberately no credits/contributor list, matching an explicit
  instruction not to add one (there wasn't one before this tab existed,
  and none is added now).
- A new "⋯" quick-menu chip next to the search bar offers the existing
  Paged/Vertical-Scroll toggle plus an Open Settings shortcut.
  Deliberately no "sort by" entry — this app has no automatic sort feature
  (manual drag order only), so a menu item for it would be decorative,
  not functional.
- Settings now floats above the still-visible launcher instead of
  replacing it. `LauncherWindowController` used to hide the launcher
  before ever opening Settings; that's removed, and
  `SettingsWindowController`'s window level is now one above the Dock
  (matching/above `LauncherWindow`'s own `dockLevel - 1`), with the same
  `collectionBehavior` so it can actually render in front. Implemented as
  a level/`collectionBehavior` change on the existing titled window rather
  than converting it to a borderless panel — same visual outcome, notably
  less risk (the native close button and key-window text-field behavior
  are untouched).
- A new first-run onboarding wizard (`Sources/Onboarding`) — welcome /
  trigger methods / permissions / done — shown once via a `UserDefaults`
  flag, gated ahead of the launcher's first appearance on a genuine first
  run. Deliberately read-only: it explains the existing defaults rather
  than letting the user reconfigure them, so there's no duplicate
  settings-mutation logic to keep in sync with the real Settings window.

**On reverse-engineering, explicitly**: the user asked, twice, for a
competing app's compiled binary to be decompiled and its internals used as
an implementation reference for the features above. This was declined —
reverse-engineering a third-party proprietary binary and using it to guide
a public MIT-licensed repo's implementation creates real copyright/EULA/
trade-secret exposure for the repo itself, independent of whether any code
is literally copied. Everything above was built from public APIs and this
project's own established patterns, using only what's visible in
screenshots for UI/UX reference.

Verification: `swift test` 87/87 passing (+3 over the previous round: a
runtime finger-count-switch test, two `OnboardingState` tests). Release
build verified via `log stream`: normal launch and both
`LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG` paths show no errors;
`LAUNCHPAD_DEBUG_FORCE_ONBOARDING=1` shows no errors and the process stays
alive. Visual results (does Settings actually read as floating over the
grid, does the onboarding wizard look right) could not be screenshotted in
this session — `screencapture` only captured this session's own
foreground window rather than the launched app — so those two specifically
still need the user's own look.

**Two real bugs from hands-on testing of the round above, fixed the same
day.** (1) Onboarding and the launcher could appear at once — the default-
on bottom-right hot corner got armed before the onboarding-vs-launcher
decision, so it could fire mid-launch (if the cursor already happened to
be near that corner) and pop the launcher open right on top of the
wizard. Trigger registration is now deferred until onboarding is actually
skipped or finished. (2) Horizontal swipe paging stopped working — the
vertical-axis addition could lock onto a transient vertical blip (real
fingers landing on a trackpad almost always produce one before a
horizontal sweep takes over) and then silently discard the rest of that
gesture's clearly-horizontal motion. Horizontal now gets unconditional
engage priority, identical to its pre-vertical-support behavior; vertical
only claims a gesture when it clearly dominates (>2x horizontal's
magnitude). `swift test`: 87/87. The axis-lock fix specifically can't be
exercised by the existing debug hook (it drives `GridViewController`'s
drag methods directly, bypassing `GridCollectionView`'s event-driven state
machine) — verified by code review only; needs the user's own trackpad
test to confirm.

**Known limitations:**
- Only English and Japanese are localized so far. macOS's other ~38
  supported languages are intentionally deferred to a later round —
  `Sources/Localization/Resources/{en,ja}.lproj/Localizable.strings` is
  where additional `<lang>.lproj` directories would go.
- The Settings window's "Vertical Scroll" layout mode is stored/persisted
  but not actually implemented in `GridViewController`/`PagedGridLayout` yet
  — selecting it changes a setting with no visual effect. Paged mode is the
  only one that renders.
- The Settings window's hotkey toggle has no key-capture UI behind it yet
  (`TriggerSettings.hotkeyKeyCode` stays `nil`), so enabling it currently
  registers nothing — `GlobalHotkeyTrigger` itself works (Phase 5), only the
  Settings-side key recorder is missing.
- Search-list aliasing: renamed apps show the alias in the main grid, but
  the flat search-results list (shown while typing) still shows the
  original name — `LauncherViewModel`/`LauncherFiltering` don't have access
  to `GridModel`'s aliases yet.
- Xcode.app is required for `swift test` (Command Line Tools alone can't
  resolve `Testing`/`XCTest`) and will also be needed for Instruments-based
  performance work (Phase 9).
- The Catalog scan is ~15-20x slower in a debug build than release
  (SHA256 identity hashing + `Bundle`/code-signing reads are not
  representative unoptimized): 99 real apps took ~9s in debug vs. ~540ms in
  `-c release`. Benchmark with `swift build -c release` before drawing any
  performance conclusion.

**Round 7: Codable backward-compatibility retrofit, defensive folder-prune
hardening, and a Settings tab reorg with three new controls.**

`GridSettings`, `TriggerSettings`, and `LayoutDocument` now use hand-written
`Codable` (`decodeIfPresent(...) ?? default`) instead of the synthesized
conformance. A synthesized decoder requires every key present in the JSON,
so adding any new field to these types — which this project has now done
more than once (`multitouchFingerCount`, and this round's `sortMode`/
`hideDockWhileLauncherOpen`) — would fail to decode any real `layout.json`
saved before that field existed, falling through past the last-known-good
backup (usually the same old schema) straight to an empty document. All
three types decode new fields leniently now. A new regression test strips
the newer keys from a real encoded document and confirms it still decodes
with sensible defaults. Separately, `GridModel.pruneMissingItems` now
dissolves any folder left empty after pruning (reusing the same
`isFolderEmpty`/`dissolveFolder` pair the user-driven removal path already
used) and logs exactly what gets pruned, via a new `DiagnosticsLog.grid`
category.

**Correction, in the interest of accuracy**: this hardening was originally
prompted by what looked like a real, confirmed data-loss bug — two legacy-
imported folders ("その他"/"ゲーム") appearing to have 0 items in a live
`layout.json`, despite project history recording them as populated at
import time. Re-checking with the actual `Folder` schema
(`pages: [[LayoutItem]]`) found this was a misreading: the original
diagnostic script checked a JSON key ("items") that doesn't exist in this
schema — the real key is "pages" — so it read as empty regardless of the
file's actual contents. The folders' real contents were intact the whole
time; there was no data loss. The two hardening changes above are kept
regardless (defensively correct, no synthesized-`Decodable` risk either
way), but the specific bug they were originally framed as fixing didn't
exist.

Settings is reorganized from six tabs (Grid/Triggers/Sources/Hidden/
Uninstall/About) into five (General/Screen/Apps/Advanced/About), mirroring
a reference app's structure per a user-confirmed mapping: General holds
the old Triggers content, Screen holds the old Grid content plus the three
new controls below, Apps holds the old Hidden content, and Advanced merges
Sources and Uninstall behind a segmented sub-tab picker (their view shapes
— a plain form vs. a master-detail list — are different enough that
merging them into one layout wasn't worth it). New Screen-tab controls:
**Sort By** (Custom/Name only — Date Added/Last Used aren't implemented,
since neither piece of metadata is tracked anywhere yet, and a menu entry
for them would be decorative rather than functional), applying immediately
and sorting within each existing page/folder-page without changing page
boundaries or folder membership; **Reorganize**, a manual one-shot button
calling the grid's existing (now-public) tight-repack logic under the
current, unchanged settings; and **Hide Dock**, which switches which side
of the Dock's own window level the launcher sits on (default keeps Phase
14's "Dock renders on top" behavior; enabling it reverts to painting over
the Dock like before Phase 14) — this never touches the real Dock process
or macOS's own autohide setting, only this app's own window level.

`swift test`: 91/91 passing. Release build verified via `log stream`:
normal launch and the Advanced/Uninstall debug-hook path both show no
errors, process stays alive. The tab reorg's actual visual result still
needs the user's own look — this session's `screencapture` consistently
captures its own foreground window rather than the launched app, a
limitation reconfirmed (not worked around) this round.

**Fixed a real page-drag bug: the previous page flashed at the end of a
swipe transition.** User report: "right at the moment it switches, the
previous app shows." `finishPageDrag` reset the live `collectionView`'s
transform to 0 — its on-screen position — *before* calling `reloadData()`,
so for however long AppKit took to actually lay out and draw the reloaded
cells, the view sat on-screen still showing the *old* page; removing the
neighbor snapshot overlay (which had covered it with the correct new-page
image throughout the drag) right after exposed that stale frame. Fixed by
doing the reload, plus a forced synchronous `layoutSubtreeIfNeeded()` +
`displayIfNeeded()`, while the view is still off-screen (at whatever
transform the settle spring left it at), and only then resetting the
transform and removing the neighbor — by the time either becomes visible,
the content is already correct. `swift test`: 91/91. Verified via
`LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG=commit` through `log stream`: the state
machine still completes correctly (page 0 → 1, no errors); this proves the
mechanics survived the reorder, not the absence of the visual flash
itself, which needs the user's own look.

**Prefetch adjacent pages' icons ahead of time.** User report: icons
visibly "popped in" a few seconds after switching pages, and swiped-to
pages looked blank right at the moment they were revealed.
`itemForRepresentedObjectAt:` only starts fetching an icon once its cell
is actually about to be displayed, so any page nobody has looked at yet
starts every cell blank; the live drag-neighbor snapshot has the same
problem one layer down, since it can only use `cachedIconIfAvailable` (a
synchronous peek). New `GridViewController.prefetchAdjacentPageIcons()`
fires off async icon fetches for every app on the pages adjacent to
`currentPage`, called from `reload()` (covers initial load) and from both
places `currentPage` actually changes — the standing invariant is "pages
adjacent to whatever's shown are already warm," covering both a swipe
revealing a neighbor and a discrete dot/arrow jump. `swift test`: 91/91
(no new automated test — `GridViewController` has no unit-test harness of
its own). Verified empirically: cleared the on-disk icon cache, launched
fresh with zero interaction, and confirmed ~80 icons got cached (roughly
two pages' worth, not just the ~35 actually visible) — proving the
adjacent page was warmed proactively rather than on first view.

**Diagnosed and tuned the page-drag commit "looks like a fade, not a
slide" report using real captured swipe data.** User report matched
exactly what the drag-tracked design is supposed to do (page follows the
finger, slides continuously, commits past a distance/velocity threshold)
— but said what actually happened read as a fade instead. Rather than
guess at another change in an area with two prior real-hardware failures,
added `DiagnosticsLog.grid` logging at every decision point in
`GridCollectionView.scrollWheel` and `GridViewController.beginPageDrag`/
`updatePageDrag`/`endPageDrag`, then asked the user to reproduce and share
`log stream` output. The captured log proved the mechanism itself works —
both real swipes correctly engaged the continuous path, created a
neighbor snapshot, and committed — but revealed why it still looked wrong:
both commits resolved from short, fast flicks (76-211pt dragged,
1000-2300pt/s release velocity), so the settle spring had to visibly
travel nearly the *entire* remaining page width using a spring
(damping 1.0, response 0.32) tuned for a short correction — completing
with no overshoot in well under half a second, reading as an abrupt snap.
Commit now uses its own spring (damping 0.86, response 0.45 — a touch of
momentum-appropriate bounce per apple-design's guidance for flick/release-
driven motion) with more time for the eye to follow the slide; abort keeps
the original fast spring since it only ever travels the short distance
actually dragged. Also raised the settle-duration clamp from 0.6s to
1.0s so the longer commit spring can't get cut off mid-flight by the
scheduled data-swap. `swift test`: 91/91. Verified via
`LAUNCHPAD_DEBUG_SIMULATE_PAGE_DRAG=commit`: correct commit, no errors.
This tunes feel, which still needs the user's own confirmation — the log
evidence proves the mechanics, not that the new timing feels right.

Follow-up user report: "next page's content isn't visible during the
drag." Added a pixel-sampling diagnostic to `renderPageSnapshot`
(`GridViewController.swift`) and confirmed via `debugSimulatePageDrag` +
`log stream` that the neighbor-page snapshot bitmap was 100% transparent
(0/64 sampled points) even though `cacheDisplay(in:to:)` reported success.
Root cause: the offscreen `NSCollectionView` used to render a page's
snapshot was never inserted into a real `NSWindow`; `cacheDisplay`'s
display path only produces real pixels for layer-backed views (every
`GridCellItem` sets `wantsLayer = true`) that have actually been drawn by
a window at least once. Fixed by briefly hosting the offscreen collection
view in a permanent, never-visually-shown `NSWindow` (parked far outside
any display's coordinate space) just long enough to render, then ordering
it back out. Re-verified with the same diagnostic: sampled points are now
non-transparent (5/64, 12/64 across two pages — low counts are expected,
since most of a page is empty grid space between icons, not missing
content). `swift test`: 91/91.

Added two more `Sort By` modes: `Date Added` (newest first) and `Last
Used` (most recently launched first), alongside the existing `Custom`/
`Name`. Backed by two new persisted maps on `LayoutDocument`,
`dateAddedByID` and `lastUsedByID`. `dateAddedByID` is stamped when
`GridModel.reconcile(with:)` places a genuinely new app; every app
already in an existing real grid (added before this field existed) gets
backfilled with synthetic, strictly-increasing timestamps based on its
current position — apps get appended to the end over time, so existing
order is the best available proxy for "roughly when added." `lastUsedByID`
is stamped by `GridModel.recordLaunch(for:)`, called from the single
funnel every launch path (grid click, search result, folder contents)
goes through, plus the two "Open New Instance" context-menu actions that
bypass it. Both new sorts are one-shot, same as `Name` — applying the
mode reorders once; it isn't continuously re-enforced, so launching an
app under `Last Used` doesn't yank it to the top mid-click. Folders have
no timestamp of their own and sort to the end under both modes. New
tests cover the ordering, the backfill's position-based reversal, and
Codable round-trip/back-compat for the two new fields — 95/95 passing.
Verified against the real installed `layout.json`: the backfill populated
`dateAddedByID` for all ~93 real apps with no errors or data loss.

**Build note**: while adding this, confirmed that plain `swift build`/
`swift test` in this iCloud-synced checkout can silently read a stale
build database (the disk-I/O-error issue mentioned in Build & Run below)
and skip recompiling changed files without surfacing an error — a bare
`swift test` run reported the old test count with none of a set of
already-edited new tests included. Always use the `--scratch-path`
invocation from Build & Run when verifying changes, not just when running
`Scripts/build-app.sh`.

User report: "search bar can't be clicked, focused, or typed into,"
plus a brief flicker on page moves, plus a request to be able to group
apps. Root-caused the search-field issue with a new debug hook
(`LAUNCHPAD_DEBUG_SETTINGS_KEY_RECLAIM`) rather than guessing:
`LauncherWindowController.windowDidResignKey` unconditionally called
`hide()` whenever the launcher resigned key — including when a
*different window of the same app* (Settings) became key instead of a
genuinely different app taking focus. Opening Settings therefore hid
the launcher immediately, silently undoing the Round 6 design where
Settings floats above the still-visible grid. Fixed by checking
`NSApp.isActive` (stays true when key merely moved to another of this
app's own windows, only goes false on a real "clicked a different app").
Even with that fixed, `LauncherWindow` (a `.nonactivatingPanel`) doesn't
automatically regain key status the way an ordinary window would once
Settings actually closes, so `SettingsWindowController.onWillClose`
(deferred one run-loop turn past `windowWillClose` — calling it
synchronously got silently overwritten by `NSWindow.close()`'s own
in-flight teardown) now calls
`LauncherWindowController.reclaimKeyIfVisible()`, which also
re-activates the app first. Verified end-to-end via the new debug hook:
confirmed `isKeyWindow == false` after Settings closed before this fix,
`true` after — real reproduction, not just code review.

Separately, reduced a plausible flicker source in the page-drag
snapshot mechanism: `snapshotHostWindow` (from the earlier blank-
neighbor-snapshot fix) now orders itself front exactly once at creation
instead of on every single drag gesture, since repeatedly ordering even
an off-screen window in and out of the window list still forces a
WindowServer composite pass each time. This is a reasonable, low-risk
simplification, not independently proven to eliminate the reported
flicker — still needs the user's own retest.

Folder creation via drag (`createOrJoinFolder`, the deferred-launch-vs-
drag handling in `didSelectItemsAt`) was reviewed and found already
correctly wired — no bug found there. Since the key/focus bug above
could plausibly make any click-and-drag interaction unreliable
depending on timing, worth retrying now that it's fixed before
concluding folder creation itself needs work. `swift test`: 95/95.

Follow-up user report: the search field still didn't work — clicking it
closed the launcher entirely. Added a one-time frame-logging diagnostic
to `LauncherViewController.viewDidAppear` and had the user capture
`log stream` while reproducing: the click landed at (730, 985), squarely
within the search field's own logged frame (683.5, 980, 342.5, 24), yet
`BackgroundClickCatcherView.mouseDown` fired instead — the click was
being swallowed by `searchBarGlass` (`NSGlassEffectView` on macOS 26),
even though it's already placed as a decorative *sibling* behind
`searchIcon`/`searchField` specifically to avoid Apple's documented
z-order quirk for glass views. That sibling-ordering workaround wasn't
sufficient here — the glass view still won hit-testing for at least
some points within its bounds. Fixed by making both glass background
implementations (`NSGlassEffectView` and the `NSVisualEffectView`
fallback) hard-disable their own `hitTest` (always returns `nil`) — a
purely decorative layer can now never be a hit target, so clicks always
fall through to whatever real control is drawn in front of or around
it, regardless of any internal z-order behavior. `swift test`: 95/95.

That glass-hitTest fix turned out not to be the actual cause — the user
confirmed it was still broken. Root-caused properly this time with a
new debug hook (`LAUNCHPAD_DEBUG_CLICK_SEARCH_FIELD`) that dispatches a
real synthetic `NSEvent` mouse down/up pair at the search field's exact
location via `window.sendEvent`, alongside direct `hitTest` probes.
The probes showed `hitTest` was never the problem — it always correctly
resolved to the search field. But dispatching the click for real (even
calling `searchField.mouseDown(with:)` directly, bypassing
`window.sendEvent` entirely) still ended up in
`BackgroundClickCatcherView.mouseDown`. That only makes sense as an
`NSResponder`-chain fallback: `searchField.cell` is replaced with a
fresh `SearchFieldCell()`, but a bare `NSTextFieldCell()` defaults to
*not* editable/selectable (unlike `NSTextField`'s own convenience
initializers, which configure that for you). With `isEditable`/
`isSelectable` never set, the cell declined to track the click,
`NSControl.mouseDown` fell back to `super.mouseDown(event)`, and that
walked the responder chain up through the field's superviews until it
reached `BackgroundClickCatcherView.mouseDown` — indistinguishable from
a real background click, closing the launcher every time. Fixed by
setting both properties right after assigning the custom cell.
Re-verified with the same hook: `hitTest` now resolves to the field
editor's `NSTextView` after the click, and the background catcher no
longer fires at all.

Also, while investigating a still-open "app grouping via drag" report:
added an explicit `setDraggingSourceOperationMask(.every, forLocal:
true)` (local in-collection-view drags are tracked as a separate mask
from drags to another app/the Dock, which already had `forLocal:
false` set), plus diagnostic logging across the drag/drop delegate
methods. Not independently verified — a real native
`NSCollectionView` drag session can't be synthesized as directly as a
single click — still needs the user's own retest. `swift test`: 95/95.

## Item drag: lift, live reorder, folder creation, page-turn

The user provided a detailed specification (iOS-home-screen-style icon
dragging, translated from its SwiftUI-flavored pseudocode to this
project's AppKit/CALayer idioms) and asked for a full implementation.
This replaces NSCollectionView's built-in click/selection/drag
machinery for grid cells entirely — that machinery fires selection
synchronously on mouseDown before it's known whether the gesture
continues into a drag, and has no notion of live neighbor displacement,
folder-candidate hover zones, or drag-triggered page turning.

`GridCollectionView` now exposes `onItemMouseDown`/`onItemMouseDragged`/
`onItemMouseUp` instead of forwarding content clicks to `super`.
`GridViewController` drives a custom state machine from these:

- **Press feedback**: scale 1.00→0.96 on mouseDown, distinct from drag lift.
- **Click-vs-drag**: a 6pt distance threshold; short of that, mouseUp
  launches/opens the item exactly as before.
- **Lift**: the pressed cell's real live view is snapshotted (`cacheDisplay`
  — safe here since the cell has genuinely been displayed by the real
  window already, unlike the offscreen-snapshot pitfall from the earlier
  page-drag bug) into a floating `NSImageView` that tracks the cursor 1:1
  (respecting grab offset), scales to 1.06 with a touch of bounce, gets a
  shadow. The original cell hides.
- **Live reorder preview**: nearest-remaining-cell + a short debounce timer
  (a simplified stand-in for the spec's precise hysteresis band) determines
  an insertion slot; every other item's real live view springs to its
  preview position via layer transform. `model.pages` itself is untouched
  until the drop actually commits.
- **Folder candidate**: hovering the center ~60% of another *app* for a
  dwell delay (500ms) highlights it as a folder target — only apps can be
  a folder-creation source, matching `GridModel.createOrJoinFolder`'s
  existing semantics.
- **Page-edge turning**: holding near an edge for a dwell delay (450ms)
  turns the page. The dragged icon is a floating overlay on the root view,
  independent of the collection view being transformed, so it stays fixed
  under the pointer while only the grid/page indicator slide — the spec's
  explicit "don't carry the grabbed icon along with the page" requirement.
- **Settle/cancel**: spring to the final cell on drop; revert-to-origin on
  cancel (wired to the existing background-click safety net).

**Deferred, explicitly**: the spec's exact geometric hysteresis margins,
Cmd+Arrow/Option+Arrow keyboard reorder/page-move shortcuts, dragging an
icon out to the real Dock (previously free via NSCollectionView's native
drag session + `.fileURL` pasteboard — removed along with that machinery),
and giving `FolderContentsViewController`'s own grid the same rich system.

Verified via a new `LAUNCHPAD_DEBUG_SIMULATE_ITEM_DRAG=reorder|folder`
debug hook (synthetic points through the real `handleItemMouseDown/
Dragged/Up` methods): folder creation confirmed end-to-end (folder count
increased, no crash), reorder confirmed end-to-end (clean commit, no
folder created), and cancellation via a background click confirmed to
revert cleanly with no crash. `swift test`: 95/95. The drag's actual feel
still needs the user's own hands-on retest.

**Follow-up, real regression found from user report** ("dragging does
nothing, folders can't even be opened, nothing works"): `handleItemMouseDown`
called `collectionView.reloadItems(at: [indexPath])` to make the selection
highlight visible — but reloading the exact cell that just received
`mouseDown` reconfigures (and can recreate) that view instance. AppKit
routes subsequent `mouseDragged`/`mouseUp` to whichever view received
`mouseDown`, so swapping that view's identity out from under an
in-flight press broke every gesture starting with a click, not just
drags. Fixed by not reloading at all — `GridCellItem.applySelection(_:)`
is now internal so the highlight can be toggled directly on the
already-existing live cell views instead.

Also discovered (and cleaned up) while investigating: the debug hook
above had been mutating the real, persisted `layout.json` on every test
run (it calls the actual `model.moveItem`/`createOrJoinFolder` +
`model.save()`), leaving two "New Folder" 2-item test artifacts behind
— very likely what read as "folder looks terrible." Confirmed via the
real file and cleaned up with a temporary, one-off debug hook (already
removed from source) using the existing `removeFromFolder` path; the
two real folders were untouched throughout. Lesson for future testing
in this area: back up/restore `layout.json` around any debug run that
exercises real model mutations.

`swift test`: 95/95. Still needs the user's own hands-on retest — a
real click or drag can't be performed from this session.

**Follow-up regression**: "properly dragging, the grabbed app flies off,
operations don't work." `updateItemDrag` reassigned
`floatingView.frame.origin` on every drag update, while that view's
layer also carried the lift's scale transform (set via a raw
`CATransform3DMakeScale` assignment). `NSView.frame` is computed
against the view's untransformed geometry — reassigning it while a
layer transform is active (and, during the lift's spring, still
mid-animation) fights with that transform instead of composing with
it, producing erratic drift. Every other continuous drag in this
codebase (page-drag, reorder preview) avoids this by never touching
`.frame` after initial placement and driving movement purely through
`transform.translation.x/y` — this was the one place that broke from
that pattern. Fixed by making the floating view's `.frame` immutable
after creation: the lift now sets `transform.scale` via its structured
keypath (not a raw matrix assignment), and cursor-following/settle/
revert all drive movement via `transform.translation.x/y` deltas from
the fixed original frame instead. Verified via
`LAUNCHPAD_DEBUG_SIMULATE_ITEM_DRAG=reorder` against a backed-up copy
of the real `layout.json` (restored immediately after, per the lesson
above): clean commit, no crash. `swift test`: 95/95.

**The actual "nothing works" cause, found via a genuine (not simulated)
drag**: rewrote `LAUNCHPAD_DEBUG_SIMULATE_ITEM_DRAG` to dispatch through
`window.sendEvent` instead of calling `handleItemMouseDown/Dragged/Up`
directly (three prior fix attempts in this area all missed real
regressions because direct calls bypass `GridCollectionView`'s own
`mouseDown`/`mouseDragged`/`mouseUp` overrides entirely — the same blind
spot the search-field bug exposed), and added logging to those overrides
themselves. This version, running live during verification, captured a
*genuine* concurrent trackpad drag: `mouseDown` -> `mouseDragged` ->
`beginItemDrag` all fired correctly, but `mouseUp` never arrived — no
further log line for 12+ seconds. AppKit's per-window "keep routing to
whoever got mouseDown" continuity isn't guaranteed if the pointer leaves
the window's bounds, key status changes mid-drag, or other real-world
cases a synthetic in-bounds test never hits. With no way out,
`activeItemDrag` stayed non-nil forever — the floating icon stuck on
screen, every subsequent press treated as still mid-drag, freezing all
grid interaction. Unlike the page-drag machinery (which has had a hard
fallback timer since an early round for exactly this failure class), the
item-drag system had no safety net at all. Added two, mirroring that
established pattern: a 15s fallback timer that force-reverts, and a
*global* mouseUp monitor that commits the drag if a real mouseUp lands
anywhere in the app while one is still active (idempotent against the
normal path — whichever fires first wins, the other sees `nil` and
no-ops). `swift test`: 95/95. Release build launches cleanly.

**4th round, root-caused via Plan Mode + an Explore-agent static review**:
user report — "nothing improved, the grabbed icon doesn't move from its
spot, surrounding icons shift oddly, and for some reason only the top
item opens." This codebase has a consistent internal convention: every
place that continuously mutates a CALayer transform either sets
`wantsLayer = true` on that exact view first, or pairs the write with an
active `CAAnimation`. Two places broke from it: (1) `GridViewController.view`
(the plain root `NSView`) was never `wantsLayer = true` — the floating
drag-preview's only active animation was the one-shot "lift" spring
(auto-removed after ~0.2s), after which `updateItemDrag`'s per-frame bare
`transform.translation` writes had nothing keeping that layer under
active compositing, so the model value updated but stopped reliably
repainting ("doesn't move from its spot"); (2) `endItemDrag`/`revertItemDrag`
called `stopWobble()` (which removes cells' one continuous animation)
*before* `resetItemTransform`'s own bare identity-transform write — that
reset could likewise fail to repaint, leaving cells visually stuck at
their last offset even though hit-testing (always computed from
untransformed layout) had already reverted to normal, explaining "only
the top one opens." Fixed: `root.wantsLayer = true` in `loadView()`;
reordered both methods to reset transforms before `stopWobble()`, not
after. Also added `GridCellItem.prepareForReuse()` (previously absent)
as defense-in-depth against recycled cells inheriting stale transform/
animation/hidden state. Verified against a backed-up/restored real
`layout.json`; also caught, live, a *second* genuine concurrent user
drag whose `mouseUp` was again lost via the normal path but correctly
recovered by the global-monitor safety net from the prior round —
confirming that fix holds up under repeated real use. `swift test`: 95/95.

**5th round, root-caused from a live (non-synthetic) `log stream` capture
of the user's actual trackpad use**: user report — "after one drag's
movement breaks, dragging a different app afterward makes the *first*
app move instead — a strange kind of breakage." A passive capture (no
synthetic events injected, just `log stream` running while the user
tried it themselves) caught the exact sequence twice: `mouseDown` on
item A → `beginItemDrag` → **a second `mouseDown` on item B, with no
`mouseUp` for item A in between** (the same real-world lost-`mouseUp`
gap the global monitor above exists for) → a long run of `mouseDragged`
→ eventually one `mouseUp` → `endItemDrag` committing item **A** (not
B) to B's slot. Root cause: `handleItemMouseDown` never checked whether
a drag was already active — it only overwrote `pendingItemPress`,
leaving the stale `activeItemDrag` in place. Since
`handleItemMouseDragged` checks `activeItemDrag` before
`pendingItemPress`, every drag update after the second press kept
driving item A's session instead of starting a fresh one for item B.
Fixed: `handleItemMouseDown` now commits any still-active session via
`endItemDrag` (using its own last-tracked position — same treatment as
a genuinely lost `mouseUp`) before handling the new press, so a fresh
`mouseDown` always starts clean. Added a purpose-built debug hook
(`LAUNCHPAD_DEBUG_SIMULATE_ITEM_DRAG=interrupt`) that reproduces this
exact interleaving via real `window.sendEvent` dispatch; `log stream`
confirmed the new "committing the stale session first" log fires and a
proper `beginItemDrag` follows for the second item. `swift test`:
95/95. Verified against a backed-up/restored real `layout.json` (the
debug hook exercises the same real `model.moveItem`/`save()` path as
production).

**6th round, root-caused with genuine OS-level input for the first time
this project** — the user granted Accessibility permission to the host
app mid-session, which unlocked real `CGEventPost`-driven mouse drags
(indistinguishable from actual hardware input, unlike every prior
verification method in this saga) plus real screenshots via
`screencapture`. This is what finally exposed two structurally different
bugs hiding behind the same symptom ("the grabbed icon still doesn't
move"):

1. **`cell.view.isHidden = true` broke `mouseDragged` continuity.**
   `createFloatingDragView` hid the original cell so only the floating
   snapshot would be visible — but setting `isHidden` on a descendant of
   `collectionView` (not `collectionView` itself) silently broke AppKit's
   "the view that got `mouseDown` keeps getting `mouseDragged`/`mouseUp`"
   continuity for the rest of the gesture. A real drag would fire
   `mouseDown` → one `mouseDragged` → `beginItemDrag`, then never receive
   another `mouseDragged` at all — confirmed by toggling only that one
   line (6/6 synthetic drag events got through with it removed; the
   1-event cutoff came back every time it was restored). Same bug family
   as the `reloadItems`-mid-`mouseDown` regression documented at
   `handleItemMouseDown` — mutating view-hierarchy/visibility state on the
   actively-tracked view's subtree mid-gesture is unsafe. Fixed by hiding
   the cell through its `CALayer` `opacity` instead, which never touches
   AppKit's own view-visibility machinery.
2. **`updateItemDrag` mixed point-conversion and rect-conversion across a
   flipped/non-flipped boundary.** `floatingViewOriginalFrameInRoot` is
   computed by converting the cell's *rect* from `collectionView`
   (flipped) to `view` (non-flipped) — `NSView.convert(_ rect:to:)`
   automatically corrects for the flip, so its `minY` always means "the
   visual bottom edge" in the destination space. `updateItemDrag`
   converted the drag target as a bare *point* instead, which doesn't get
   that same correction. Diagnostic logging showed the result directly: a
   purely horizontal drag produced `dy == the cell's own height` on every
   single frame, never 0 — so the floating icon tracked the cursor
   correctly on X but jumped to a wildly wrong Y position instead of
   staying level. Fixed by building a full rect on both sides of the
   subtraction so they agree on what `minY` means.

Verified end-to-end: real `CGEventPost` drags (not `window.sendEvent`) at
20 steps/50ms produced all 20 `mouseDragged` events reaching
`GridCollectionView` and a correct `endItemDrag` commit (previously: 1
event, then silence); real screenshots taken mid-drag show the floating
icon lifted, shadowed, and tracking the cursor exactly along the drag
axis with no vertical drift. `swift test`: 95/95. The real `layout.json`
was repeatedly touched by this round's verification (the same real
`model.moveItem`/`createOrJoinFolder`/`save()` path production code
uses) and was backed up before and restored after.

## UI polish round (2026-07-26) — folder popover, search text, menu bar, duplicate Settings entry

User feedback (with reference screenshots from a competing paid launcher,
used only for layout/visual inspiration — no branding, copy, or paywall
gating copied) plus real Accessibility-driven testing (real `CGEventPost`
clicks + real `screencapture` screenshots) surfaced several concrete bugs:

1. **Folders wouldn't open.** `NSPopover.contentSize` (set by the caller)
   has no effect once the content view controller's view uses Auto
   Layout — undocumented gotcha, but real: `FolderContentsViewController`
   had no explicit size constraints of its own, so Auto Layout collapsed
   it to the smallest size its children could shrink to, and the popover
   appeared stuck at roughly the folder icon's own size instead of
   opening. Fixed via `preferredContentSize` (the mechanism that *does*
   work for Auto-Layout view controllers) plus explicit width/height
   constraints on the root view.
2. **Nothing inside an opened folder was clickable.** `FolderContentsViewController`
   reuses `GridCollectionView`, whose `mouseDown` override never calls
   `super.mouseDown(with:)` for a content hit — it only calls
   `onItemMouseDown`, which this controller never wired up. Wired a
   minimal click-only handler (no drag/reorder machinery needed for a
   flat folder list). Verified end-to-end: clicking Chess inside the
   "ゲーム" folder actually launched `/System/Applications/Chess.app`.
3. **Search field text sat visibly higher than the search icon next to
   it**, despite both being centerY-anchored to the same pill. Same root
   cause as the isEditable/isSelectable bug from an earlier round: a bare
   `NSTextFieldCell()` doesn't inherit `NSTextField`'s convenience-init
   defaults — this time `usesSingleLineMode`/`wraps`, not
   editability. Without single-line mode, the cell laid out the text as
   if it could wrap, top-anchoring it instead of true single-line
   vertical centering. Fixed by setting `usesSingleLineMode = true` and
   `wraps = false` explicitly.
4. **The real macOS menu bar sat visibly over the fullscreen launcher.**
   Never hidden — this app only positioned its window at the right
   level, never told the system to treat this as a fullscreen-style
   presentation. Fixed with `NSApp.presentationOptions.insert(.autoHideMenuBar)`
   in `show()` (removed again in `hide()`), matching how every other
   fullscreen-presenting macOS app behaves — independent of the existing
   `hideDockWhileLauncherOpen` toggle, which is about the Dock icon strip
   specifically.
5. **Two routes opened the same Settings window** — a permanently-visible
   gear chip *and* the quick menu's "Open Settings…" item. Removed the
   standalone gear chip/button entirely; the quick menu (⊙) is now the
   only entry point, matching the reference design's single "•••" chip
   with no separate persistent gear icon.

Verified via real Accessibility-driven interaction throughout (this
project's first access to genuine OS-level clicks + real screenshots,
not `window.sendEvent`/`log stream` inference): folder popover opens at
its real 320×320 size with a visible app grid, clicking an app inside
launches it, search text now sits level with the search icon, the menu
bar disappears once the launcher shows, and only one settings icon
remains in the search bar. `swift test`: 95/95. Real `layout.json` was
backed up before and restored after each round of interactive testing.

**Not yet addressed this round** (carried forward): the icon hit-test
area still reportedly feels oversized in some cases; the page-indicator
dots were seen missing on a cold launch in one capture but present on a
later one — cause not yet isolated; the icon-size Settings control's
real-world effect hasn't been re-verified; and the folder icon/popover
still use the original design (a generic folder glyph + count badge,
plain grid of labeled icons) rather than the reference's content-preview
tile and label-free row.

## Requirements

- macOS 26+, Apple Silicon
- Swift 6 toolchain (Xcode Command Line Tools are sufficient; the full Xcode.app
  IDE is not required — this project builds via Swift Package Manager)

## Build & Run

This repo lives under `~/Documents`, which is iCloud-synced. SwiftPM's build
database gets disk I/O errors if `.build` sits inside a synced folder, so
always pass an out-of-iCloud `--scratch-path`:

```sh
SCRATCH=~/.cache/launchpad-native/build

swift build --scratch-path "$SCRATCH"       # build all targets
swift test --scratch-path "$SCRATCH"        # run unit tests
./Scripts/build-app.sh                       # assembles $SCRATCH/LaunchpadNative.app (LSUIElement)
open "$SCRATCH/LaunchpadNative.app"
```

## Architecture

See module boundaries and phase plan in `Sources/` as they land:
`AppHost`, `Diagnostics`, and (in later phases) `Catalog`, `Launcher`, `Grid`,
`Persistence`, `Triggers`, `PrivateAPI`, `WindowBrowser`, `Uninstall`,
`Settings`.

Private/undocumented system APIs (LaunchServices SPI, SkyLight,
MultitouchSupport, low-level HID key handling) are used where no public
equivalent exists, always behind a resolver that verifies symbols at runtime
rather than linking against guessed signatures. Where macOS 26 now ships a
public replacement (e.g. `NSGlassEffectView`, `SMAppService`,
`OSSystemExtensionRequest`, `NSWindow.CollectionBehavior`), the public API is
used instead.

## Third-Party Dependencies

None. This project has no Swift Package Manager dependencies (no
`Package.resolved` — check `Package.swift`'s `dependencies:` to confirm)
and links only Apple's own system frameworks (AppKit, SwiftUI,
ServiceManagement, ScreenCaptureKit, SystemExtensions, Security, etc.) plus
the system's `libsqlite3` for the legacy Launchpad DB import. There is no
third-party license list because there is nothing to list.

## Contributing & Security

See [`CONTRIBUTING.md`](CONTRIBUTING.md) for build/test expectations and
this project's rules around private-API changes, and
[`SECURITY.md`](SECURITY.md) for how to report a vulnerability.

## License

MIT — see `LICENSE`.
