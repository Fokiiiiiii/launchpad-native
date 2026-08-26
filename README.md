# LaunchpadNative

A replacement for Launchpad, which macOS 26 removed. Press a key or pinch the
trackpad, your apps appear in a grid over whatever you were doing, you pick
one, it goes away.

It runs as a background utility with no Dock icon of its own, reads the apps
already installed on the machine, and keeps its own arrangement of them —
including the folders and page order from the old Launchpad, imported on first
launch.

Source only. No App Store build, no installer, no paid tier.

## What it does

**Opening it.** F4 out of the box, plus a hot corner (bottom-right by default),
a global hotkey you choose, or a four- or five-finger pinch on the trackpad.
Each is optional and configurable. Escape, a click on the background, or
launching something closes it.

**Finding an app.** Start typing. Results rank by how well they match — the
whole name first, then the start of it, then a word inside it, then an
abbreviation ("vsc" finds Visual Studio Code). Japanese names are searchable by
their reading, so メモ answers to "memo" and システム設定 to "settei", without
switching input modes. Apps you have opened recently come first among equally
good matches. Arrow keys move the selection, Return opens it.

**Arranging it.** Drag an icon to move it; the others get out of the way as you
go. Hold one over another to make a folder, or over the edge of the screen to
carry it to the next page. Folders open into a panel you can page through,
rename in place, and rearrange inside. Right-click any icon to reveal it in
Finder, keep it in the Dock, rename it, hide it, list its open windows, or
uninstall it.

**Settings** (five tabs: General, Screen, Apps, Advanced, About) cover the
triggers, the grid's rows and columns, icon size, sort order, the background,
whether the real Dock stays on top, login-at-start, a menu-bar icon, hidden
apps, and a diagnostics export. Available in English, Japanese, Simplified
Chinese, Korean, German, French and Spanish.

**Uninstalling other apps** finds what an app left behind — caches,
preferences, application support — shows you the list with sizes, and moves
what you tick to the Trash.

## Requirements

macOS 26 or later, Apple Silicon, and a Swift 6 toolchain. Xcode Command Line
Tools are enough; the full Xcode app is not needed.

## Build and run

```sh
./Scripts/build-app.sh release
open ~/Applications/LaunchpadNative.app
```

That builds the bundle, signs it, and installs it to `~/Applications`. Run it
once and it stays resident, waiting for a trigger.

For development, `./Scripts/build-app.sh` with no argument builds the debug
configuration, which is the one that carries the `LAUNCHPAD_DEBUG_*` hooks used
for verification — they are compiled out of release builds entirely, so an
environment variable can never reach into someone else's grid.

```sh
SCRATCH=~/.cache/launchpad-native/build
swift build --scratch-path "$SCRATCH"
swift test  --scratch-path "$SCRATCH"
```

The `--scratch-path` matters: this repository sits in an iCloud-synced folder,
and SwiftPM's build database hits disk I/O errors when `.build` is synced.

## How it is put together

| Module | Responsibility |
| --- | --- |
| `AppHost` | The resident process: startup order, trigger wiring, window controllers |
| `Catalog` | Finding installed apps, watching for changes, caching icons |
| `Persistence` | The saved layout — atomic writes, last-known-good backup |
| `Grid` | The icon grid, dragging, folders, paging |
| `Launcher` | The overlay window, search, background |
| `Triggers` | Hotkey, hot corner, F4, trackpad gestures |
| `WindowBrowser` | Listing and raising an app's open windows |
| `Settings` `Onboarding` `WhatsNew` `Uninstall` | The panels |
| `DesignSystem` `Localization` `Diagnostics` | Shared surfaces, strings, logging |

Private system APIs are used only where no public equivalent exists
(MultitouchSupport for finger counts, SkyLight for the menu bar), always
through a resolver that checks for the symbol at runtime rather than linking
against a guessed signature. Where macOS 26 ships a public replacement —
`NSGlassEffectView`, `SMAppService`, `NSWindow.CollectionBehavior` — that is
what gets used.

Pure logic is kept out of the view controllers so it can be tested directly:
grid geometry, spring math, search ranking, trigger policy, log retention. The
test suite is ~380 cases and runs in about fifteen seconds.

## Dependencies

None. No Swift Package Manager dependencies at all — only Apple's own
frameworks, plus the system `libsqlite3` for reading the old Launchpad
database on first launch.

## More

- [`docs/engineering-log.md`](docs/engineering-log.md) — round-by-round notes
  on what broke, what the measurements said, and what was tried and reverted
- [`CONTRIBUTING.md`](CONTRIBUTING.md) — build and test expectations, and the
  rules around private-API changes
- [`SECURITY.md`](SECURITY.md) — reporting a vulnerability

## License

MIT — see [`LICENSE`](LICENSE).
