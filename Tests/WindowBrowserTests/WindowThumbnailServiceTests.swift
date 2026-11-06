import AppKit
import Testing
@testable import WindowBrowser

private func window(_ id: Int) -> WindowInfo {
    WindowInfo(id: id, title: "w\(id)", ownerBundleIdentifier: "com.example.app", ownerProcessID: 1,
               frame: CGRect(x: 0, y: 0, width: 400, height: 300), isOnScreen: true)
}

private actor Captures {
    private(set) var count = 0
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func started() { count += 1 }
    func waitUntilOpen() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() {
        open = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

/// A page of cells asks for its thumbnails all at once; the same window asked
/// for while its capture is running must join it rather than start another.
@Test func concurrentRequestsForOneWindowShareOneCapture() async {
    let captures = Captures()
    let service = WindowThumbnailService(ttl: .seconds(60)) { _ in
        await captures.started()
        await captures.waitUntilOpen()
        return NSImage(size: NSSize(width: 1, height: 1))
    }

    async let first = service.thumbnail(for: window(1))
    async let second = service.thumbnail(for: window(1))
    try? await Task.sleep(for: .milliseconds(100))
    await captures.release()
    _ = await (first, second)

    #expect(await captures.count == 1)
}

/// Closing the browser empties the cache; a capture that was already running
/// must not fill it again behind that.
@Test func aCaptureStartedBeforeEvictAllDoesNotRepopulateTheCache() async {
    let captures = Captures()
    let service = WindowThumbnailService(ttl: .seconds(60)) { _ in
        await captures.started()
        await captures.waitUntilOpen()
        return NSImage(size: NSSize(width: 1, height: 1))
    }

    async let pending = service.thumbnail(for: window(1))
    try? await Task.sleep(for: .milliseconds(100))
    await service.evictAll()
    await captures.release()
    _ = await pending

    _ = await service.thumbnail(for: window(1))
    #expect(await captures.count == 2, "the stale result was served from the cache")
}
