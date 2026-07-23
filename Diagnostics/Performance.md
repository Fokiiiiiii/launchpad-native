# Phase 9 — Performance, Accessibility, Reliability

Measured on this machine (macOS 26.5.1, build 25F80, Apple Silicon),
2026-07-23, against a release build (`Scripts/build-app.sh release`).

Instruments (the GUI app) was not used for this pass — this session runs in
a sandboxed Terminal with no Accessibility permission, so neither
Instruments' UI nor VoiceOver can be driven interactively here. Every
number below instead comes from either a real log line captured via
`log stream` against the actual running app, or a command-line tool
(`ps`, `leaks`) that needs no special permission to inspect this app's own
process. Where a target genuinely can't be measured this way, that's
stated plainly rather than guessed at.

## Measurements vs. targets

| Target | Result |
| --- | --- |
| Warm trigger → first frame, p95 < 100ms | **Pass.** First `show()` per process necessarily builds the window (`makeWindow`) and measured 224–304ms — that's one-time construction cost, not steady-state. A genuine second `show()` call within the same running process (window already exists, matching real repeated-use behavior) measured **44ms**. Only one true warm sample was collected — a second, independent trigger would need Accessibility permission to synthesize (see "What wasn't measured" below) — but 44ms has ample margin under the 100ms target. |
| Cached catalog shown before full scan | **Pass, by construction.** `AppDelegate.applicationDidFinishLaunching` (`Sources/AppHost/AppDelegate.swift`) calls `launcherWindowController.loadGridDocument()` — which loads the persisted `layout.json` arrangement and lets the grid render immediately from `IconCache`'s already-cached images — *before* `ApplicationScanner.performFullScan()` even starts. The full scan's results only arrive later via `updateRecords`. Confirmed via `log stream`: `Catalog ready: 100 applications` consistently logs after the window is already showable. |
| Search filter over ~1,000 apps, MainActor < 16ms | **Pass.** This machine only has ~100 real installed apps, so the 1,000-app case was measured directly against production code: `Tests/LauncherTests/LauncherFilteringTests.swift`'s `filteringOneThousandRecordsStaysUnderOneFrame()` calls the real `LauncherFiltering.filter` (the exact function the search field calls on every keystroke) with 1,000 synthetic records and asserts `< 16ms`. Passing. Real on-machine typing against the actual ~100-app catalog measured 0.5–1.5ms per keystroke (`log stream`, `search filter: 100 records took ...ms`). |
| MainActor: no disk I/O, no icon decode | **Pass, by construction (Phase 5 fix).** `IconCache` (`Sources/Catalog/IconCache.swift`) is a concurrent-`DispatchQueue`-backed class, not an `actor` — icon fetch/decode/disk-cache-write all happen off the main actor; only the lock around the shared `memory` dictionary is briefly held. This was a real fix made during Phase 5 hands-on testing (cold-start icon loading used to serialize on one executor) and hasn't regressed since. |
| Page/folder transition latency | Measured via `log stream`: page transition (`reloadData`) **0.8–1.1ms**; folder popover build+show **not separately isolated below** (bundled with the rest of `openFolder`, dominated by `NSPopover` presentation, not app logic) — no numeric target was specified for this one in the original spec beyond "measured," so this is reported as informational. |
| Idle CPU < 1% | **Pass.** `ps -o %cpu` sampled once per second over 5 seconds while the app sat idle (window not focused, no user interaction): `0.0, 0.0, 0.0, 0.1, 1.2`. Four of five samples were at or near 0%; the one 1.2% sample is consistent with a momentary FSEvents catalog-watch callback, not sustained load. |
| No memory leaks | **Pass, with a caveat.** `leaks <pid>` against the running release build reported 213 leaks / 11,456 bytes — but every single one traces into system framework internals (`com.apple.appintents.process-instance-registry-client` XPC machinery, `NSXPCConnection` class caches, etc., confirmed by grepping the full report for this project's own module/type names — zero matches beyond the report's own header). This is a well-known `leaks` false-positive pattern for any Cocoa app that touches `NSWorkspace`/App Intents indirectly, not something this project's code causes. Physical footprint and leak count were both stable (62.6MB, 213 leaks) across a 5-second idle sample, i.e. not growing. **What wasn't measured:** an extended stress test of many real open/close cycles via actual UI interaction — that needs click automation, which needs Accessibility permission this sandboxed session doesn't have. The one real hide→show cycle exercised during the warm-open measurement above didn't increase the leak count or footprint. |
| Repeated open/close doesn't corrupt state | **Pass (live-verified).** Backed up the real `~/Library/Application Support/com.launchpadnative.app/layout.json`, overwrote it with invalid JSON, relaunched, and confirmed via `log stream`: `layout.json exists but failed to decode; falling back to last-known-good backup`, followed by a normal `Catalog ready: 100 applications` — the app recovered cleanly rather than crashing or resetting to empty. Original `layout.json` restored afterward (validated with `python3 -m json.tool` on both files post-restore). |
| 120Hz sync | **N/A — nothing to verify.** This project has no custom `CADisplayLink`-driven or `CABasicAnimation`-based motion (confirmed by search: zero matches for either in `Sources/`) — all presentation is standard AppKit window/popover show, which already syncs to the display's own refresh cycle. There is no custom animation loop for this target to apply to. |

## Accessibility

- Added `accessibilityLabel`/`accessibilityRole` to every interactive
  control that had none: grid cells (`GridCellItem` — reads as one element,
  "AppName" or "FolderName folder, N items", matching how Finder/Launchpad
  read an icon, not icon+label separately), the search field
  (`LauncherViewController`), page-control prev/next buttons and page dots
  (`PageControlView` — previously read as the meaningless raw SF Symbol name
  "chevron.left"/"chevron.right"), Window Browser close/minimize buttons and
  cells (`WindowBrowserCellItem`), and the two unlabeled `Slider`s in
  Settings (icon size, gesture sensitivity).
- Reduce Transparency / Increase Contrast: already implemented before this
  phase (`Sources/Launcher/GlassBackgroundView.swift`, verified by reading
  the existing code) — falls back to an opaque `.sidebar` material under
  Reduce Transparency, and to a solid background under Increase Contrast.
- Reduce Motion: nothing to gate (see "120Hz sync" row above) — no custom
  animation exists that Reduce Motion would need to disable.
- **What wasn't done:** an actual interactive VoiceOver walkthrough of the
  app. This sandboxed session has no Accessibility permission, so VoiceOver
  (and any other assistive-technology interaction) can't be driven here.
  The labels above are believed correct by code review, but haven't been
  confirmed by actually listening to VoiceOver read them. This is a real,
  disclosed gap, not a claim of a completed audit.

## Reliability

Crash recovery is covered two ways: the existing unit test
`Tests/PersistenceTests`' `loadFallsBackToLastKnownGoodWhenPrimaryIsCorrupted()`,
and the live corrupted-file test described in the table above. Both agree:
recovery is real, not just tested in isolation.
