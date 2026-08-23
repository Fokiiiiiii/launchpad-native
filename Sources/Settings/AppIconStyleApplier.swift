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
        // `NSApp` is an implicitly-unwrapped optional that stays nil until the
        // application object exists — before `NSApplication.shared` is first
        // touched, and in any host that never creates one. Force-unwrapping it
        // here crashed outright the first time this was called outside a
        // running app. There is also nothing to apply in that case: the icon
        // being set is the *process's* Dock representation, which only means
        // anything once there is a process showing one.
        guard let app = NSApp else { return }
        app.applicationIconImage = previewImage(for: style) // nil falls back to the bundle's own .icns
    }
}
