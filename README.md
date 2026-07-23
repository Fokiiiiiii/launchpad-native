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

**Known limitations:**
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
