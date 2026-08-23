import Foundation

/// SwiftPM's default `Bundle.module` resolution looks at
/// `Bundle.main.bundleURL` first (the `.app` bundle's *root*, not
/// `Contents/Resources/`), then falls back to a hardcoded absolute path
/// into the build directory. For a hand-assembled `.app` (this project has
/// no Xcode project — `Scripts/build-app.sh` copies files into
/// `Contents/Resources/` itself), the first check always misses, so the
/// generated accessor would silently depend on the build-scratch path still
/// existing on disk rather than the resource actually being inside the
/// shipped bundle. This resolves against `Bundle.main.resourceURL`
/// (`Contents/Resources/`, the correct location for a real `.app`) first,
/// and only falls back to `Bundle.module` for `swift run`/`swift test`
/// contexts where there is no `.app` bundle at all.
public enum LocalizationBundle {
    public static let bundle: Bundle = {
        if let url = Bundle.main.resourceURL?.appendingPathComponent("LaunchpadNative_Localization.bundle"),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return Bundle.module
    }()
}
