import AppKit
import Persistence

/// Applies `AppIconStyle` to the *running* process's Dock/App-Switcher
/// representation via `NSApp.applicationIconImage` — this never touches the
/// on-disk bundle's Info.plist/.icns (impossible without re-signing an
/// unsigned build); it only affects this process's lifetime, and resets to
/// the bundle default on every relaunch, so `AppDelegate` must also call
/// `apply(_:)` once at launch time.
@MainActor
public enum AppIconStyleApplier {
    public static func previewImage(for style: AppIconStyle) -> NSImage? {
        guard let url = Bundle.main.resourceURL?
            .appendingPathComponent("AppIconVariants")
            .appendingPathComponent("\(style.rawValue).png") else { return nil }
        return NSImage(contentsOf: url)
    }

    public static func apply(_ style: AppIconStyle) {
        NSApp.applicationIconImage = previewImage(for: style) // nil falls back to the bundle's own .icns
    }
}
