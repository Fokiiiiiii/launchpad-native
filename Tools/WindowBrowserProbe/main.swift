// Phase 7 manual verification: enumerates real windows for a given bundle
// identifier and (optionally) activates the first one, proving the public
// ScreenCaptureKit + Accessibility pipeline works end-to-end on this machine.
import AppKit
import WindowBrowser

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let bundleID = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "com.brave.Browser"

Task {
    let windows = await WindowEnumerator.windows(forBundleIdentifier: bundleID)
    print("Found \(windows.count) window(s) for \(bundleID)")
    for window in windows {
        print("  id=\(window.id) title=\"\(window.title)\" frame=\(window.frame)")
    }

    if let first = windows.first {
        let service = WindowThumbnailService()
        if let thumbnail = await service.thumbnail(for: first) {
            print("Captured thumbnail: \(thumbnail.size)")
        } else {
            print("Thumbnail capture failed")
        }
        print("AX trusted: \(AXIsProcessTrusted())")
        WindowActivator.activate(first)
        print("Activated window \(first.id)")
    }
    exit(0)
}
RunLoop.main.run(until: Date().addingTimeInterval(10))
