import CoreServices
import Foundation

/// Thin wrapper over the public `FSEventStreamCreate` API (CoreServices),
/// used so `ApplicationScanner` can do differential updates instead of a
/// full rescan on every launcher open.
import CLaunchpadCore

private final class WatcherCallbackContext {
    let roots: [String]
    let onChange: ([String]) -> Void
    init(roots: [String], onChange: @escaping ([String]) -> Void) {
        self.roots = roots
        self.onChange = onChange
    }
}

final class FSEventsWatcher: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: UnsafeMutableRawPointer?
    private var callbackContext: UnsafeMutableRawPointer?

    init?(paths: [String], latency: CFTimeInterval = 0.15, onChange: @escaping ([String]) -> Void) {
        guard !paths.isEmpty else { return nil }
        let allocated = paths.map { strdup($0) }
        defer { allocated.forEach { free($0) } }
        guard allocated.allSatisfy({ $0 != nil }) else { return nil }
        let pointers: [UnsafePointer<CChar>?] = allocated.map { $0.map { UnsafePointer($0) } }
        let context = Unmanaged.passRetained(WatcherCallbackContext(roots: paths, onChange: onChange)).toOpaque()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UnsafePointer<CChar>?>?, UInt, Int32) -> Void = { context, paths, count, rescan in
            guard let context else { return }
            let state = Unmanaged<WatcherCallbackContext>.fromOpaque(context).takeUnretainedValue()
            if rescan != 0 { state.onChange(state.roots); return }
            guard let paths, let count = Int(exactly: count) else { return }
            state.onChange((0..<count).compactMap { paths[$0].map { String(cString: $0) } })
        }
        let watcher = pointers.withUnsafeBufferPointer { buffer in
            launchpad_watch_start(buffer.baseAddress, UInt(buffer.count), latency, context, callback)
        }
        guard let watcher else {
            Unmanaged<WatcherCallbackContext>.fromOpaque(context).release()
            return nil
        }
        handle = watcher
        callbackContext = context
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        let watcher = handle
        let context = callbackContext
        handle = nil
        callbackContext = nil
        guard let watcher else { return }
        launchpad_watch_stop(watcher)
        if let context { Unmanaged<WatcherCallbackContext>.fromOpaque(context).release() }
    }

    deinit { stop() }
}
