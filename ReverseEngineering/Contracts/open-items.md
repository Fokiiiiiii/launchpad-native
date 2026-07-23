# Phase 1 — remaining unverified work

Symbol/class existence and a first signature sanity-pass are done (see the
other contract files). The following still need real, on-machine
verification before the phases that depend on them proceed:

- **LaunchServices selectors** — actual method list on `LSApplicationWorkspace`
  / `LSApplicationRecord` via Objective-C runtime introspection
  (`class_copyMethodList`), not assumed from community headers. Blocks Phase 2.
- **MultitouchSupport contact frame struct** — register a real callback,
  capture one real thumb+3-finger pinch as a fixture, freeze the struct
  layout from observed bytes. Blocks Phase 5.
- **CGEventTap under the real app bundle** — re-run the tap-creation check
  from the actual `LaunchpadNative.app` bundle (distinct TCC identity from
  this `swift run` process) after granting Input Monitoring. Blocks Phase 5.
- **SkyLight mutating calls** (`SLSOrderWindow`, `SLSSetWindowLevel`,
  `SLSCopyWindowsWithOptionsAndTags`) — only read-only connection/space calls
  have been call-verified so far; anything that changes window state needs
  its own real-call check against a disposable test window. Blocks Phase 7.
- **Launchpad layout store/consumer on macOS 26** — **partially resolved**:
  the legacy DB (`$(getconf DARWIN_USER_DIR)com.apple.dock.launchpad/db/db`)
  **does exist on this machine** (dated 2023-era, last modified 2026-06-09,
  157 rows in `items` / 142 in `apps`) and its schema matches the spec
  exactly (`items(rowid, uuid, flags, type, parent_id, ordering)`,
  `apps(item_id, title, bundleid, storeid, category_id, moddate, bookmark)`).
  So Phase 4's read-only import has a real, non-empty fixture to build and
  test against on this machine. Still open: whether macOS 26 has a *separate,
  currently-live* consumer/writer for this DB (i.e. does the modern Spotlight/
  App browser still read or write it, or is this file simply stale/orphaned
  from an older OS install) — that determines whether import should be
  framed as "one-time migration of stale data" or "still-synced source."
  Needs one more check: modify nothing, but diff `db`'s `moddate` against
  actual Launchpad/Spotlight usage on this machine to see if it's still being
  touched. Blocks Phase 4's exact framing (not the read path itself, which is
  ready to implement).
- **Privileged Helper communication** — **resolved: not viable under this
  project's constraints.** Tested live (Phase 8 part 4): `SMAppService.daemon(plistName:).register()`
  fails with `SMAppServiceErrorDomain Code=1 "Operation not permitted"` on
  an ad-hoc-signed build (`TeamIdentifier=not set`). See
  `privileged-helper.md` for the full result. Root-owned artifact removal
  remains permanently unimplemented; `RemovalExecutor` refuses those items
  and the UI directs the user to remove them manually.
- **Dock drag acceptance** — `NSDraggingSession` drop onto the live Dock
  process has not been tried yet. Blocks Phase 4.
