import Foundation

/// Best-effort recursive size estimate, meant to run off the main actor —
/// Application Support/Caches for some apps (browsers, dev tooling) can run
/// into many gigabytes and many thousands of files, and must never block the
/// Uninstall panel from appearing while it walks a directory tree.
import CLaunchpadCore
enum DiskSizeEstimator {
    static func estimatedSize(at url: URL) -> Int64 {
        url.withUnsafeFileSystemRepresentation { path in
            guard let path else { return 0 }
            return launchpad_disk_usage(path)
        }
    }
}
