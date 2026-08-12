import AppKit
import Diagnostics
import Foundation

/// Decodes and caches app icons off the main actor.
///
/// Icon loading is kept off the main actor and bounded by finite concurrency.
/// Requests for the same cache key share one in-flight fetch, while the
/// memory/disk queues have explicit caps so a catalog refresh cannot retain or
/// encode an unbounded number of images.
///
/// Cache format switched from TIFF (which encodes multiple resolution
/// representations) to a single fixed-size PNG, and the disk write is
/// fire-and-forget so it never delays returning the icon to the caller.
public final class IconCache: @unchecked Sendable {
    private let cacheDirectory: URL
    /// CoreGraphics/NSWorkspace icon work is finite-concurrency rather than
    /// serial, so a cold visible page does not wait for the sum of every
    /// preceding icon fetch.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.launchpadnative.iconcache"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 4
        return queue
    }()
    private let writeQueue = DispatchQueue(label: "com.launchpadnative.iconcache.write")
    private let memoryLock = NSLock()
    private var memory: [String: NSImage] = [:]
    private var memoryOrder: [String] = []
    private let memoryLimit = 64

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<NSImage, Never>
    }
    private let requestLock = NSLock()
    private var inFlight: [String: [Waiter]] = [:]
    private var cancelledRequestIDs: Set<UUID> = []
    private let maxInFlightKeys = 128
    private let maxWaitersPerKey = 32
    private let maxCancelledRequestIDs = 256

    private let writeStateLock = NSLock()
    private var pendingWriteCount = 0
    private let maxPendingWrites = 8

    public init(cacheDirectory: URL? = nil) {
        let cachesDirectory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let base = cacheDirectory ?? cachesDirectory
            .appendingPathComponent("com.launchpadnative.app/icons", isDirectory: true)
        self.cacheDirectory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    public func icon(for record: ApplicationRecord, size: CGFloat = 128) async -> NSImage {
        if let cached = readMemory(record.iconCacheKey) {
            return cached
        }

        let key = record.iconCacheKey
        let requestID = UUID()
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                enqueue(
                    record: record,
                    size: size,
                    key: key,
                    requestID: requestID,
                    continuation: continuation
                )
            }
        }, onCancel: { [weak self] in
            self?.cancel(requestID: requestID, key: key, size: size)
        })
    }

    /// Synchronous best-effort peek at the in-memory cache, for callers that
    /// need an icon now and can tolerate a miss. Returns nil on a genuine
    /// cache miss rather than blocking.
    public func cachedIconIfAvailable(for record: ApplicationRecord) -> NSImage? {
        readMemory(record.iconCacheKey)
    }

    public func evictMemoryCache() {
        memoryLock.lock()
        memory.removeAll()
        memoryOrder.removeAll()
        memoryLock.unlock()
    }

    /// Internal test hook for proving the explicit memory/in-flight/write
    /// bounds without exposing cache internals to the application target.
    struct DebugState: Sendable {
        let memoryCount: Int
        let inFlightKeyCount: Int
        let pendingWriteCount: Int
    }

    func debugState() -> DebugState {
        memoryLock.lock()
        let memoryCount = memory.count
        memoryLock.unlock()
        requestLock.lock()
        let inFlightKeyCount = inFlight.count
        requestLock.unlock()
        writeStateLock.lock()
        let pendingWriteCount = self.pendingWriteCount
        writeStateLock.unlock()
        return DebugState(
            memoryCount: memoryCount,
            inFlightKeyCount: inFlightKeyCount,
            pendingWriteCount: pendingWriteCount
        )
    }

    func cacheFileURL(forKey key: String) -> URL {
        cacheDirectory.appendingPathComponent("\(key).png")
    }

    private func enqueue(
        record: ApplicationRecord,
        size: CGFloat,
        key: String,
        requestID: UUID,
        continuation: CheckedContinuation<NSImage, Never>
    ) {
        requestLock.lock()
        if cancelledRequestIDs.remove(requestID) != nil {
            requestLock.unlock()
            continuation.resume(returning: Self.placeholder(size: size))
            return
        }

        if inFlight[key] == nil, inFlight.count >= maxInFlightKeys {
            requestLock.unlock()
            continuation.resume(returning: Self.placeholder(size: size))
            return
        }

        let currentWaiterCount = inFlight[key]?.count ?? 0
        guard currentWaiterCount < maxWaitersPerKey else {
            requestLock.unlock()
            continuation.resume(returning: Self.placeholder(size: size))
            return
        }

        let shouldStart = inFlight[key] == nil
        inFlight[key, default: []].append(
            Waiter(id: requestID, continuation: continuation)
        )
        requestLock.unlock()

        if shouldStart {
            queue.addOperation { [self] in
                load(record: record, size: size, key: key)
            }
        }
    }

    private func cancel(requestID: UUID, key: String, size: CGFloat) {
        requestLock.lock()
        guard var waiters = inFlight[key] else {
            // Cancellation may race registration. The enqueue path consumes
            // this marker and resumes without launching a fetch.
            if cancelledRequestIDs.count >= maxCancelledRequestIDs {
                _ = cancelledRequestIDs.popFirst()
            }
            cancelledRequestIDs.insert(requestID)
            requestLock.unlock()
            return
        }
        guard let index = waiters.firstIndex(where: { $0.id == requestID }) else {
            requestLock.unlock()
            return
        }
        let waiter = waiters.remove(at: index)
        // Keep an empty entry until the scheduled worker calls finish().
        // This prevents a second worker from being launched while the first
        // one is still unwinding after every waiter canceled.
        inFlight[key] = waiters
        requestLock.unlock()

        waiter.continuation.resume(returning: Self.placeholder(size: size))
    }

    private func load(record: ApplicationRecord, size: CGFloat, key: String) {
        guard hasWaiters(for: key) else {
            finish(key: key, image: nil)
            return
        }

        if let cached = readMemory(key) {
            finish(key: key, image: cached)
            return
        }

        let diskURL = cacheFileURL(forKey: key)
        let diskStart = DispatchTime.now()
        if let data = try? Data(contentsOf: diskURL), let image = NSImage(data: data) {
            writeMemory(key, image)
            logSlowIfNeeded(record: record, phase: "disk-hit", start: diskStart)
            finish(key: key, image: image)
            return
        }

        let fetchStart = DispatchTime.now()
        let icon = NSWorkspace.shared.icon(forFile: record.bundleURL.path)
        icon.size = NSSize(width: size, height: size)
        logSlowIfNeeded(record: record, phase: "NSWorkspace.icon(forFile:)", start: fetchStart)

        // If every waiter canceled while the synchronous fetch was running,
        // drop the result instead of retaining another image or enqueueing a
        // disk write nobody needs.
        guard hasWaiters(for: key) else {
            finish(key: key, image: nil)
            return
        }

        writeMemory(key, icon)
        enqueueDiskWrite(icon: icon, record: record, size: size, diskURL: diskURL)
        finish(key: key, image: icon)
    }

    private func hasWaiters(for key: String) -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }
        return !(inFlight[key]?.isEmpty ?? true)
    }

    private func finish(key: String, image: NSImage?) {
        requestLock.lock()
        let waiters = inFlight.removeValue(forKey: key) ?? []
        requestLock.unlock()

        let result = image ?? Self.placeholder(size: 1)
        for waiter in waiters {
            waiter.continuation.resume(returning: result)
        }
    }

    private func enqueueDiskWrite(
        icon: NSImage,
        record: ApplicationRecord,
        size: CGFloat,
        diskURL: URL
    ) {
        writeStateLock.lock()
        guard pendingWriteCount < maxPendingWrites else {
            writeStateLock.unlock()
            return
        }
        pendingWriteCount += 1
        writeStateLock.unlock()

        writeQueue.async { [self] in
            defer {
                writeStateLock.lock()
                pendingWriteCount -= 1
                writeStateLock.unlock()
            }
            let encodeStart = DispatchTime.now()
            if let pngData = Self.pngData(for: icon, size: size) {
                try? pngData.write(to: diskURL, options: .atomic)
            }
            logSlowIfNeeded(record: record, phase: "png-encode+write", start: encodeStart)
        }
    }

    private func readMemory(_ key: String) -> NSImage? {
        memoryLock.lock()
        defer { memoryLock.unlock() }
        guard let image = memory[key] else { return nil }
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
        return image
    }

    private func writeMemory(_ key: String, _ image: NSImage) {
        memoryLock.lock()
        memory[key] = image
        memoryOrder.removeAll { $0 == key }
        memoryOrder.append(key)
        while memoryOrder.count > memoryLimit {
            let evictedKey = memoryOrder.removeFirst()
            memory.removeValue(forKey: evictedKey)
        }
        memoryLock.unlock()
    }

    /// Rasterizes to a single fixed-size bitmap and encodes as PNG.
    private static func pngData(for icon: NSImage, size: CGFloat) -> Data? {
        let pixelSize = max(Int(size * 2), 1)
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

    private static func placeholder(size: CGFloat) -> NSImage {
        NSImage(size: NSSize(width: max(size, 1), height: max(size, 1)))
    }

    private func logSlowIfNeeded(record: ApplicationRecord, phase: String, start: DispatchTime) {
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        if ms > 5 {
            DiagnosticsLog.catalog.info(
                "IconCache[\(phase, privacy: .public)] \(record.bundleIdentifier, privacy: .public) took \(ms, privacy: .public)ms"
            )
        }
    }
}
