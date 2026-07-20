# LaunchServices SPI — Tier 3 (most fragile, minimize dependence)

- Framework: `/System/Library/Frameworks/CoreServices.framework/Versions/A/Frameworks/LaunchServices.framework/LaunchServices`
- Resolution: `dlopen` the framework path first (not auto-linked by AppKit-only
  imports), then `NSClassFromString` for each class
- Verified on: macOS 26.5.1 (build 25F80), arm64

## Classes confirmed present (`NSClassFromString` succeeded)

`LSApplicationWorkspace`, `LSApplicationRecord`, `_LSQuery`.

## Not yet verified

Class *existence* only. None of the following are confirmed on this OS build
yet: instance method selectors (`allApplications`, `applicationsForBundleIdentifier:`
or equivalents), `_LSQuery` predicate construction, XPC interface used by
`launchservicesd`, or the shape of returned `LSApplicationRecord` fields
(bundle id, URL, version, team id, hidden/system flags).

**Phase 1 remaining work:** use Objective-C runtime introspection
(`class_copyMethodList`/`class_getInstanceMethod` + method encoding, not
static header import) against `LSApplicationWorkspace`/`LSApplicationRecord`
on this OS build to enumerate actual selectors before Phase 2 (Catalog)
writes any wrapper. Cross-check every derived record against the public
`NSWorkspace.shared.runningApplications` / `NSWorkspace.urlForApplication`
APIs where overlap exists, since LaunchServices is explicitly the *least*
stable dependency in this project (research notes flag this and the
Launchpad layout store as the two most fragile targets).

## Design constraint carried into Phase 2

Prefer public `NSWorkspace`/`NSMetadataQuery`(Spotlight) for anything they can
supply outright (running apps, `.app` discovery under standard directories).
Reserve `LSApplicationWorkspace`/`_LSQuery` strictly for what those public
APIs cannot give: stable internal IDs across relaunches, hidden/restricted
flags, and duplicate-bundle-id disambiguation.
