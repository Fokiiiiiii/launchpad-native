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
import CLaunchpadCore

public final class IconCache: @unchecked Sendable {
    private let cacheDirectory: URL
    /// CoreGraphics/NSWorkspace icon work is finite-concurrency rather than
    /// serial, so a cold visible page does not wait for the sum of every
    /// preceding icon fetch.
    private let queue: OperationQueue = {
        let queue = OperationQueue()
        queue.name = "com.launchpadnative.iconcache"
        queue.qualityOfService = .userInitiated
        queue.maxConcurrentOperationCount = 8
        return queue
    }()
    private let writeQueue = DispatchQueue(label: "com.launchpadnative.iconcache.write")
    private let memoryLock = NSLock()
    private let memoryIndex = launchpad_memory_cache_new(48 * 1024 * 1024, 192)
    private var memory: [UInt64: NSImage] = [:]

    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<NSImage, Never>
    }
    private struct InFlight {
        let generation: UUID
        /// The queued load for this generation, cancelled once no waiter is left.
        let operation: Operation
        var waiters: [Waiter]
    }
    private let requestLock = NSLock()
    private var inFlight: [String: InFlight] = [:]
    private var cancelledRequestIDs: Set<UUID> = []
    private let maxInFlightKeys = 256
    private let maxWaitersPerKey = 32
    private let maxCancelledRequestIDs = 256
    #if DEBUG
    private var loadStarts = 0
    #endif

    private let writeStateLock = NSLock()
    private var pendingWriteCount = 0
    private let maxPendingWrites = 8
    /// Icons are written under a name that carries the app's modification time, so
    /// every update leaves the previous file behind. Nothing else removes them, so
    /// the folder is trimmed to this many bytes, oldest first.
    private let diskBudgetBytes = 64 * 1024 * 1024
    private let writesPerTrim = 100
    /// Touched on `writeQueue` only.
    private var writesSinceTrim = 0

    public init(cacheDirectory: URL? = nil) {
        let cachesDirectory = FileManager.default
            .urls(for: .cachesDirectory, in: .userDomainMask)
            .first ?? FileManager.default.temporaryDirectory
        let base = cacheDirectory ?? cachesDirectory
            .appendingPathComponent("com.launchpadnative.app/icons", isDirectory: true)
        self.cacheDirectory = base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        // Behind the launch: the queue is serial and nothing waits on it.
        writeQueue.async { [self] in trimDiskCache(toBytes: diskBudgetBytes) }
    }

    deinit {
        launchpad_memory_cache_free(memoryIndex)
    }

    /// Deletes the oldest PNGs until the folder fits in `budget`. Age is the file's
    /// modification time, i.e. when it was written; an icon still in use that is
    /// older than the budget allows is simply drawn and written once more.
    func trimDiskCache(toBytes budget: Int) {
        cacheDirectory.withUnsafeFileSystemRepresentation { path in
            guard let path else { return }
            launchpad_trim_icon_cache(path, Int64(budget))
        }
    }

    /// What an icon is cached under: the app's own key and the size it was
    /// drawn at. The key alone returned whichever size was asked for first to
    /// every later request, so a small icon came back where a large one was
    /// wanted.
    private static func cacheKey(for record: ApplicationRecord, size: CGFloat) -> String {
        "\(record.iconCacheKey)-s\(Int(size.rounded()))"
    }

    public func icon(for record: ApplicationRecord, size: CGFloat = 128) async -> NSImage {
        let key = Self.cacheKey(for: record, size: size)
        if let cached = readMemory(key) {
            return cached
        }

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
    public func cachedIconIfAvailable(for record: ApplicationRecord, size: CGFloat = 128) -> NSImage? {
        readMemory(Self.cacheKey(for: record, size: size))
    }

    public func evictMemoryCache() {
        memoryLock.lock()
        launchpad_memory_cache_clear(memoryIndex)
        memory.removeAll()
        memoryLock.unlock()
    }

#if DEBUG
    func setIconLoadsSuspendedForTesting(_ suspended: Bool) { queue.isSuspended = suspended }
    func queuedOperationCountForTesting() -> Int { queue.operationCount }
    /// How many loads actually started, as opposed to being dropped from the queue.
    func loadStartCountForTesting() -> Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        return loadStarts
    }
    func inFlightCountForTesting() -> Int {
        requestLock.lock()
        defer { requestLock.unlock() }
        return inFlight.count
    }
#endif

    /// Internal test hook for proving the explicit memory/in-flight/write

    func cacheFileURL(forKey key: String) -> URL {
        // The key starts with an identifier from the app's own Info.plist.
        cacheDirectory.appendingPathComponent("\(BundleIdentifier.fileName(for: key)).png")
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
        let currentWaiterCount = inFlight[key]?.waiters.count ?? 0
        guard currentWaiterCount < maxWaitersPerKey else {
            requestLock.unlock()
            continuation.resume(returning: Self.placeholder(size: size))
            return
        }
        var newOperation: Operation?
        if var work = inFlight[key] {
            work.waiters.append(Waiter(id: requestID, continuation: continuation))
            inFlight[key] = work
        } else {
            let id = UUID()
            let operation = makeLoadOperation(record: record, size: size, key: key, generation: id)
            inFlight[key] = InFlight(generation: id, operation: operation, waiters: [Waiter(id: requestID, continuation: continuation)])
            newOperation = operation
        }
        requestLock.unlock()
        if let newOperation {
            queue.addOperation(newOperation)
        }
    }

    private func cancel(requestID: UUID, key: String, size: CGFloat) {
        requestLock.lock()
        guard var work = inFlight[key], let index = work.waiters.firstIndex(where: { $0.id == requestID }) else {
            if cancelledRequestIDs.count >= maxCancelledRequestIDs { _ = cancelledRequestIDs.popFirst() }
            cancelledRequestIDs.insert(requestID)
            requestLock.unlock()
            return
        }
        let waiter = work.waiters.remove(at: index)
        if work.waiters.isEmpty {
            inFlight.removeValue(forKey: key)
            requestLock.unlock()
            // Drop the queued load too, so an unstarted icon no longer holds a queue slot.
            work.operation.cancel()
        } else {
            inFlight[key] = work
            requestLock.unlock()
        }
        waiter.continuation.resume(returning: Self.placeholder(size: size))
    }

    private func makeLoadOperation(record: ApplicationRecord, size: CGFloat, key: String, generation: UUID) -> Operation {
        let operation = BlockOperation()
        // Cancelled before it starts, a block operation never runs its block, so a
        // load nobody waits for does not reach the disk or NSWorkspace.
        operation.addExecutionBlock { [self] in
            load(record: record, size: size, key: key, generation: generation)
        }
        return operation
    }

    private func load(record: ApplicationRecord, size: CGFloat, key: String, generation: UUID) {
        #if DEBUG
        requestLock.lock()
        loadStarts += 1
        requestLock.unlock()
        #endif
        guard hasWaiters(for: key, generation: generation) else { return }
        if let cached = readMemory(key) {
            finish(key: key, generation: generation, image: cached)
            return
        }
        let diskURL = cacheFileURL(forKey: key)
        let diskStart = DispatchTime.now()
        if let data = RustFileIO.read(diskURL), let image = NSImage(data: data) {
            guard hasWaiters(for: key, generation: generation) else { return }
            // Disk PNGs contain 2x pixels; retain the requested logical point size.
            image.size = NSSize(width: size, height: size)
            writeMemory(key, image)
            logSlowIfNeeded(record: record, phase: "disk-hit", start: diskStart)
            finish(key: key, generation: generation, image: image)
            return
        }
        let fetchStart = DispatchTime.now()
        let icon = NSWorkspace.shared.icon(forFile: record.bundleURL.path)
        icon.size = NSSize(width: size, height: size)
        logSlowIfNeeded(record: record, phase: "NSWorkspace.icon(forFile:)", start: fetchStart)
        guard hasWaiters(for: key, generation: generation) else { return }
        writeMemory(key, icon)
        enqueueDiskWrite(icon: icon, record: record, size: size, diskURL: diskURL)
        finish(key: key, generation: generation, image: icon)
    }

    private func hasWaiters(for key: String, generation: UUID) -> Bool {
        requestLock.lock()
        defer { requestLock.unlock() }
        guard let work = inFlight[key], work.generation == generation else { return false }
        return !work.waiters.isEmpty
    }

    private func finish(key: String, generation: UUID, image: NSImage) {
        requestLock.lock()
        guard let work = inFlight[key], work.generation == generation else {
            requestLock.unlock()
            return
        }
        inFlight.removeValue(forKey: key)
        requestLock.unlock()
        for waiter in work.waiters { waiter.continuation.resume(returning: image) }
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
                _ = RustFileIO.write(pngData, to: diskURL)
            }
            logSlowIfNeeded(record: record, phase: "png-encode+write", start: encodeStart)
            writesSinceTrim += 1
            if writesSinceTrim >= writesPerTrim {
                writesSinceTrim = 0
                trimDiskCache(toBytes: diskBudgetBytes)
            }
        }
    }

    func readMemory(_ key: String) -> NSImage? {
        var normalized = key.utf8.allSatisfy { $0 < 0x80 } ? key : key.precomposedStringWithCanonicalMapping
        memoryLock.lock()
        defer { memoryLock.unlock() }
        let id = normalized.withUTF8 { bytes in
            launchpad_memory_cache_touch(memoryIndex, bytes.baseAddress, UInt(bytes.count))
        }
        return memory[id]
    }

    func writeMemory(_ key: String, _ image: NSImage) {
        var normalized = key.utf8.allSatisfy { $0 < 0x80 } ? key : key.precomposedStringWithCanonicalMapping
        let cost = Self.estimatedImageCost(image)
        memoryLock.lock()
        defer { memoryLock.unlock() }
        var removed: [UInt64] = []
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt64>?, UInt) -> Void = { context, values, count in
            guard let context, let values, let length = Int(exactly: count) else { return }
            context.assumingMemoryBound(to: [UInt64].self).pointee.append(contentsOf: UnsafeBufferPointer(start: values, count: length))
        }
        let id = withUnsafeMutablePointer(to: &removed) { destination in
            normalized.withUTF8 { bytes in
                launchpad_memory_cache_put(memoryIndex, bytes.baseAddress, UInt(bytes.count), cost, destination, callback)
            }
        }
        for removedID in removed { memory.removeValue(forKey: removedID) }
        if id != 0 { memory[id] = image }
    }

    private static func estimatedImageCost(_ image: NSImage) -> UInt64 {
        func product(_ values: [UInt64]) -> UInt64 {
            values.reduce(1) { total, value in
                let (result, overflow) = total.multipliedReportingOverflow(by: value)
                return overflow ? UInt64.max : result
            }
        }
        func scaled(_ value: CGFloat) -> UInt64? {
            guard value.isFinite, value >= 0, value <= 32_768 else { return nil }
            return UInt64((value * 2).rounded(.up))
        }
        guard let width = scaled(image.size.width), let height = scaled(image.size.height) else { return UInt64.max }
        let displayCost = product([width, height, 4])
        var representationsCost: UInt64 = 0
        for case let bitmap as NSBitmapImageRep in image.representations where bitmap.bytesPerRow > 0 {
            let height = UInt64(max(bitmap.pixelsHigh, 0))
            let planes = bitmap.isPlanar ? max(bitmap.samplesPerPixel, 1) : 1
            let cost = product([UInt64(bitmap.bytesPerRow), height, UInt64(planes)])
            let (sum, overflow) = representationsCost.addingReportingOverflow(cost)
            representationsCost = overflow ? UInt64.max : sum
        }
        return max(1, displayCost, representationsCost)
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
