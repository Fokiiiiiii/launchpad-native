import Foundation

/// Best-effort recursive size estimate, meant to run off the main actor —
/// Application Support/Caches for some apps (browsers, dev tooling) can run
/// into many gigabytes and many thousands of files, and must never block the
/// Uninstall panel from appearing while it walks a directory tree.
enum DiskSizeEstimator {
    static func estimatedSize(at url: URL) -> Int64 {
        let fm = FileManager.default
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return 0 }
        guard isDirectory.boolValue else {
            return (try? fm.attributesOfItem(atPath: url.path)[.size] as? Int64) ?? 0
        }
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileAllocatedSizeKey, .isDirectoryKey]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: [.fileAllocatedSizeKey, .isDirectoryKey]),
                  values.isDirectory != true else { continue }
            total += Int64(values.fileAllocatedSize ?? 0)
        }
        return total
    }
}
