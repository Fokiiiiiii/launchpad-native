import CoreServices
import Foundation

/// Thin wrapper over the public `FSEventStreamCreate` API (CoreServices),
/// used so `ApplicationScanner` can do differential updates instead of a
/// full rescan on every launcher open.
final class FSEventsWatcher: @unchecked Sendable {
    private var streamRef: FSEventStreamRef?
    private let onChange: ([String]) -> Void
    private let queue = DispatchQueue(label: "com.launchpadnative.catalog.fsevents")

    init?(paths: [String], latency: CFTimeInterval = 0.75, onChange: @escaping ([String]) -> Void) {
        guard !paths.isEmpty else { return nil }
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let callback: FSEventStreamCallback = { _, clientInfo, numEvents, eventPaths, _, _ in
            guard let clientInfo else { return }
            let watcher = Unmanaged<FSEventsWatcher>.fromOpaque(clientInfo).takeUnretainedValue()
            let cPaths = eventPaths.assumingMemoryBound(to: UnsafeMutablePointer<CChar>.self)
            var changed: [String] = []
            changed.reserveCapacity(numEvents)
            for i in 0..<numEvents {
                changed.append(String(cString: cPaths[i]))
            }
            watcher.onChange(changed)
        }

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            latency,
            FSEventStreamCreateFlags(kFSEventStreamCreateFlagNoDefer)
        ) else {
            return nil
        }

        self.streamRef = stream
        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
    }

    deinit {
        if let streamRef {
            FSEventStreamStop(streamRef)
            FSEventStreamInvalidate(streamRef)
            FSEventStreamRelease(streamRef)
        }
    }
}
