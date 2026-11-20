# LaunchpadNative

A native replacement for the Launchpad that macOS 26 removed. Press a key or pinch the trackpad, pick an app, and it goes away.

## Features

- **Open it your way** — F4, a hot corner, a global hotkey, or a four- or five-finger pinch.
- **Fast search** — just start typing. Matches by name, abbreviation (`vsc`), and Japanese reading.
- **Your layout** — drag to reorder, make folders, add pages. Imports your old Launchpad layout on first launch.
- **Right-click an icon** — reveal in Finder, rename, hide, list windows, or uninstall.
- **Uninstaller** — finds leftover caches and preferences and moves what you tick to the Trash.
- **Wallpaper background** — blurred, and follows your desktop, including dynamic wallpapers.
- English, Japanese, Chinese, Korean, German, French and Spanish.

No installer, no tracking, nothing to install beyond the app. MIT licensed. The only libraries compiled in are Rust's `serde` and `serde_json`.

## Install

Requires Apple Silicon. It is designed for macOS 26 and later, with Liquid Glass, and is tested on macOS 27. The deployment target is macOS 15.0 (`Package.swift`), where the glass surfaces fall back to plain blur; that has not been verified.

1. Download `LaunchpadNative.zip` from [Releases](../../releases/latest) and unzip it.
2. Move `LaunchpadNative.app` to `/Applications`.
3. The app is not notarized, so clear the download flag once, then open it:

   ```sh
   xattr -dr com.apple.quarantine /Applications/LaunchpadNative.app
   open /Applications/LaunchpadNative.app
   ```

It stays resident and waits for a trigger (F4 out of the box).

### Build from source

Needs Xcode 27 (the macOS 27 SDK) and Rust. `Scripts/build-app.sh` builds `launchpad-core` with `cargo` (from `PATH` or `~/.cargo/bin`) before the Swift build.

```sh
./Scripts/build-app.sh release
```

This builds, signs and installs to `~/Applications/LaunchpadNative.app`.

## License

MIT — see [LICENSE](LICENSE).
