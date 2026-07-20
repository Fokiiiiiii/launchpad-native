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

**Known limitations:**
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

## License

MIT — see `LICENSE`.
