import AppKit
import Foundation

/// Decodes and caches app icons off the main actor. `NSWorkspace.icon(forFile:)`
/// is safe to call from a background context; keeping this as a plain actor
/// (not `@MainActor`) is what satisfies "icon decode must not run on
/// MainActor."
public actor IconCache {
    private let cacheDirectory: URL
    private var memory: [String: NSImage] = [:]

    public init(cacheDirectory: URL? = nil) {
        let base = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.launchpadnative.app/icons", isDirectory: true)
        self.cacheDirectory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public func icon(for record: ApplicationRecord, size: CGFloat = 128) -> NSImage {
        if let cached = memory[record.iconCacheKey] {
            return cached
        }

        let diskURL = cacheDirectory.appendingPathComponent("\(record.iconCacheKey).tiff")
        if let data = try? Data(contentsOf: diskURL), let image = NSImage(data: data) {
            memory[record.iconCacheKey] = image
            return image
        }

        let icon = NSWorkspace.shared.icon(forFile: record.bundleURL.path)
        icon.size = NSSize(width: size, height: size)
        if let tiff = icon.tiffRepresentation {
            try? tiff.write(to: diskURL)
        }
        memory[record.iconCacheKey] = icon
        return icon
    }

    public func evictMemoryCache() {
        memory.removeAll()
    }
}
