import AppKit
import Diagnostics
import Foundation

/// Decodes and caches app icons off the main actor.
///
/// This used to be an `actor`, which serialized every `icon(for:)` call onto
/// one executor — for ~35 visible cold-cache icons, that meant the total
/// wall-clock cost was the *sum* of every individual `NSWorkspace.icon(forFile:)`
/// call, not the max. A concurrent `DispatchQueue` lets multiple icon fetches
/// actually run in parallel across cores; only the shared `memory` dictionary
/// needs protecting (a lock around reads/writes), which is a much smaller
/// critical section than the whole fetch+encode+disk-write pipeline.
///
/// Cache format switched from TIFF (which encodes multiple resolution
/// representations) to a single fixed-size PNG, and the disk write is
/// fire-and-forget so it never delays returning the icon to the caller.
public final class IconCache: @unchecked Sendable {
    private let cacheDirectory: URL
    private let queue = DispatchQueue(label: "com.launchpadnative.iconcache", attributes: .concurrent)
    private let writeQueue = DispatchQueue(label: "com.launchpadnative.iconcache.write")
    private let memoryLock = NSLock()
    private var memory: [String: NSImage] = [:]

    public init(cacheDirectory: URL? = nil) {
        let base = cacheDirectory ?? FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("com.launchpadnative.app/icons", isDirectory: true)
        self.cacheDirectory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public func icon(for record: ApplicationRecord, size: CGFloat = 128) async -> NSImage {
        if let cached = readMemory(record.iconCacheKey) {
            return cached
        }

        return await withCheckedContinuation { continuation in
            queue.async { [self] in
                // Re-check: another concurrent call may have just finished
                // fetching the same icon while this one was queued.
                if let cached = readMemory(record.iconCacheKey) {
                    continuation.resume(returning: cached)
                    return
                }

                let diskURL = cacheDirectory.appendingPathComponent("\(record.iconCacheKey).png")
                let diskStart = DispatchTime.now()
                if let data = try? Data(contentsOf: diskURL), let image = NSImage(data: data) {
                    writeMemory(record.iconCacheKey, image)
                    logSlowIfNeeded(record: record, phase: "disk-hit", start: diskStart)
                    continuation.resume(returning: image)
                    return
                }

                let fetchStart = DispatchTime.now()
                let icon = NSWorkspace.shared.icon(forFile: record.bundleURL.path)
                icon.size = NSSize(width: size, height: size)
                logSlowIfNeeded(record: record, phase: "NSWorkspace.icon(forFile:)", start: fetchStart)

                writeMemory(record.iconCacheKey, icon)
                continuation.resume(returning: icon)

                // Fire-and-forget: never delays returning the icon above.
                writeQueue.async {
                    let encodeStart = DispatchTime.now()
                    if let pngData = Self.pngData(for: icon, size: size) {
                        try? pngData.write(to: diskURL)
                    }
                    self.logSlowIfNeeded(record: record, phase: "png-encode+write", start: encodeStart)
                }
            }
        }
    }

    public func evictMemoryCache() {
        memoryLock.lock()
        memory.removeAll()
        memoryLock.unlock()
    }

    private func readMemory(_ key: String) -> NSImage? {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        return memory[key]
    }

    private func writeMemory(_ key: String, _ image: NSImage) {
        memoryLock.lock()
        memory[key] = image
        memoryLock.unlock()
    }

    /// Rasterizes to a single fixed-size bitmap and encodes as PNG — much
    /// cheaper than `NSImage.tiffRepresentation`, which bundles multiple
    /// resolution representations into one file.
    private static func pngData(for icon: NSImage, size: CGFloat) -> Data? {
        let pixelSize = Int(size * 2) // @2x for Retina without over-allocating further
        guard let bitmap = NSBitmapImageRep(
            bitmapDataPlanes: nil,
            pixelsWide: pixelSize,
            pixelsHigh: pixelSize,
            bitsPerSample: 8,
            samplesPerPixel: 4,
            hasAlpha: true,
            isPlanar: false,
            colorSpaceName: .deviceRGB,
            bitmapFormat: [],
            bytesPerRow: 0,
            bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmap)
        icon.draw(in: NSRect(x: 0, y: 0, width: pixelSize, height: pixelSize))
        NSGraphicsContext.restoreGraphicsState()

        return bitmap.representation(using: .png, properties: [:])
    }

    /// Temporary timing instrumentation to find where cold-start icon
    /// loading actually spends time, rather than guessing further.
    private func logSlowIfNeeded(record: ApplicationRecord, phase: String, start: DispatchTime) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        if ms > 5 {
            DiagnosticsLog.catalog.info("IconCache[\(phase, privacy: .public)] \(record.bundleIdentifier, privacy: .public) took \(ms, privacy: .public)ms")
        }
    }
}
