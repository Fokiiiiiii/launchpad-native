import Foundation
import Testing
@testable import Catalog

/// Holds a scan open until the test lets it finish, and says when a scan has
/// reached the hold, so the test can interleave other work deterministically.
import Darwin

private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var callCount = 0

    var waitingCount: Int { waiters.count }

    func nextCall() -> Int {
        callCount += 1
        return callCount
    }

    var totalCalls: Int { callCount }

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

private func untilWaiting(_ gate: Gate) async throws {
    for _ in 0..<2_000 {
        if await gate.waitingCount > 0 { return }
        try await Task.sleep(nanoseconds: 2_000_000)
    }
}

private func source(_ id: String) -> ApplicationSource {
    ApplicationSource(id: id, rootURL: URL(fileURLWithPath: "/tmp/\(id)"), recursive: false, priority: 0)
}

private func makeRecord(_ name: String, in sourceID: String, subfolder: String? = nil) -> ApplicationRecord {
    let folder = subfolder.map { "/tmp/\(sourceID)/\($0)" } ?? "/tmp/\(sourceID)"
    let url = URL(fileURLWithPath: "\(folder)/\(name).app")
    let identifier = "com.example.\(sourceID).\(name)"
    return ApplicationRecord(
        id: StableAppID(bundleURL: url, bundleIdentifier: identifier, teamIdentifier: nil),
        bundleIdentifier: identifier,
        bundleURL: url,
        executableURL: nil,
        displayName: name,
        originalDisplayName: name,
        bundleVersion: "1.0",
        teamIdentifier: nil,
        category: nil,
        sourceID: sourceID,
        isSystemProtected: false,
        isBackgroundOnly: false,
        iconCacheKey: identifier,
        canLaunch: true,
        canOpenNewInstance: false,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

private func report(
    _ records: [ApplicationRecord],
    failed: [URL] = [],
    unreadable: [URL] = []
) -> ApplicationBundleReader.ScanReport {
    ApplicationBundleReader.ScanReport(outcome: .scanned(records), failedDirectories: failed, unreadableBundles: unreadable)
}

@Test func benchmarkScannerReconciliationMemory() async {
    guard ProcessInfo.processInfo.environment["LAUNCHPAD_BENCHMARK"] == "1" else { return }
    let count = Int(ProcessInfo.processInfo.environment["LAUNCHPAD_MEMORY_ITEMS"] ?? "1000") ?? 1000
    guard (1...10_000).contains(count) else { return }
    let records = (0..<count).map { makeRecord("App\($0)", in: "bench") }
    let scanner = ApplicationScanner(sources: [source("bench")], scanReport: { _, _ in report(records) })
    _ = await scanner.performFullScan()
    func peak() -> Int {
        var usage = rusage()
        _ = getrusage(RUSAGE_SELF, &usage)
        return usage.ru_maxrss
    }
    let baseline = peak()
    let start = DispatchTime.now().uptimeNanoseconds
    for _ in 0..<5 { _ = await scanner.performFullScan() }
    let elapsed = DispatchTime.now().uptimeNanoseconds - start
    #expect(await scanner.currentSnapshot().recordsByID.count == count)
    print("MEMORY_BENCH scenario=scanner-reconcile items=\(count) baseline_bytes=\(baseline) peak_bytes=\(peak()) elapsed_ns=\(elapsed)")
}

private func ids(_ scanner: ApplicationScanner) async -> Set<StableAppID> {
    Set(await scanner.currentSnapshot().records.map(\.id))
}

/// A scan result is authoritative: the grid prunes what it does not list and
/// saves. Applying one that has been overtaken put back apps the user had just
/// removed from the configuration — and the grid then saved that.
@Test func aSlowScanOfTheOldSourcesCannotOverwriteTheNewConfiguration() async throws {
    let gate = Gate()
    let oldApp = makeRecord("Old", in: "old")
    let newApp = makeRecord("New", in: "new")
    let scanner = ApplicationScanner(sources: [source("old")], scanReport: { source, _ in
        if source.id == "old" {
            await gate.wait()
            return report([oldApp])
        }
        return report([newApp])
    })

    let slow = Task { await scanner.performFullScan() }
    try await untilWaiting(gate)
    await scanner.replaceSources([source("new")])
    #expect(await ids(scanner) == [newApp.id])

    await gate.open()
    _ = await slow.value

    #expect(await ids(scanner) == [newApp.id])
}

@Test func duplicateIDsFollowSourceOrderAndUnreadableCarryDoesNotOverwriteNewerRecord() async {
    let lowSource = ApplicationSource(id: "low", rootURL: URL(fileURLWithPath: "/tmp/low"), recursive: false, priority: 0)
    let highSource = ApplicationSource(id: "high", rootURL: URL(fileURLWithPath: "/tmp/high"), recursive: false, priority: 10)
    let low = makeRecord("Same", in: "low")
    var changed = low
    changed.sourceID = "high"
    changed.displayName = "Higher priority"
    let high = changed
    let calls = Gate()
    let scanner = ApplicationScanner(sources: [highSource, lowSource], scanReport: { source, _ in
        if source.id == "high" {
            if await calls.nextCall() == 1 { return report([high]) }
            return ApplicationBundleReader.ScanReport(outcome: .unreadable, failedDirectories: [])
        }
        return report([low])
    })
    let initial = await scanner.performFullScan()
    #expect(initial.recordsByID[low.id]?.displayName == "Higher priority")
    let after = await scanner.performFullScan()
    #expect(after.recordsByID[low.id]?.displayName == low.displayName)
    #expect(after.recordsByID.count == 1)
}

@Test func aChangedSourceWithTheSameIDRejectsAnOlderScan() async throws {
    let gate = Gate()
    let old = ApplicationSource(id: "apps", rootURL: URL(fileURLWithPath: "/tmp/old-apps"), recursive: false, priority: 0)
    let replacement = ApplicationSource(id: "apps", rootURL: URL(fileURLWithPath: "/tmp/new-apps"), recursive: false, priority: 0)
    let oldApp = makeRecord("Old", in: "apps")
    let newApp = makeRecord("New", in: "apps")
    let scanner = ApplicationScanner(sources: [old], scanReport: { source, _ in
        if source == old {
            await gate.wait()
            return report([oldApp])
        }
        return report([newApp])
    })
    let slow = Task { await scanner.performFullScan() }
    try await untilWaiting(gate)
    await scanner.replaceSources([replacement])
    await gate.open()
    _ = await slow.value
    #expect(await ids(scanner) == [newApp.id])
}

@Test func anOlderScanOfTheSameSourceCannotReplaceANewerResult() async throws {
    let gate = Gate()
    let stale = makeRecord("Stale", in: "apps")
    let current = makeRecord("Current", in: "apps")
    let scanner = ApplicationScanner(sources: [source("apps")], scanReport: { _, _ in
        if await gate.nextCall() == 1 {
            await gate.wait()
            return report([stale])
        }
        return report([current])
    })

    let first = Task { await scanner.performFullScan() }
    try await untilWaiting(gate)
    _ = await scanner.performFullScan()
    #expect(await ids(scanner) == [current.id])

    await gate.open()
    _ = await first.value

    #expect(await ids(scanner) == [current.id])
}

// MARK: Folders that could not be read

/// A folder inside a readable source that cannot be listed is not "no apps
/// here". Reading it as that told the grid every app in it was uninstalled.
@Test func appsInAFolderThatCouldNotBeReadAreKeptNotReportedUninstalled() async {
    let calls = Gate()
    let inside = makeRecord("Inside", in: "apps", subfolder: "locked")
    let outside = makeRecord("Outside", in: "apps")
    let lockedFolder = URL(fileURLWithPath: "/tmp/apps/locked")
    let scanner = ApplicationScanner(sources: [source("apps")], scanReport: { _, _ in
        if await calls.nextCall() == 1 { return report([inside, outside]) }
        return report([outside], failed: [lockedFolder])
    })

    await scanner.performFullScan()
    await scanner.performFullScan()

    #expect(await ids(scanner) == [inside.id, outside.id])
}

// MARK: Bundles that could not be read

/// An app being updated has its folder but, for a moment, no readable Info.plist.
/// That is not "uninstalled": reading it as that dropped the app's place from the
/// pages and folders for good, and it came back as a new app at the end.
@Test func anAppWhoseBundleCouldNotBeReadIsKeptNotReportedUninstalled() async {
    let calls = Gate()
    let updating = makeRecord("Updating", in: "apps")
    let other = makeRecord("Other", in: "apps")
    let scanner = ApplicationScanner(sources: [source("apps")], scanReport: { _, _ in
        switch await calls.nextCall() {
        case 1: return report([updating, other])
        case 2: return report([other], unreadable: [updating.bundleURL])
        default: return report([other])
        }
    })

    await scanner.performFullScan()
    await scanner.performFullScan()
    #expect(await ids(scanner) == [updating.id, other.id])

    // Once it can be listed no more, it really is gone.
    await scanner.performFullScan()
    #expect(await ids(scanner) == [other.id])
}

/// The launch cache drops a record whose bundle changed since it was written. It
/// is still the last thing known about that app, so the first scan may fall back
/// on it, but only for a bundle that was listed and could not be read.
@Test func aRecordTheLaunchCacheCouldNotVouchForIsOnlyAFallbackForAnUnreadableBundle() async {
    let calls = Gate()
    let cachedStale = makeRecord("Stale", in: "apps")
    let alsoStale = makeRecord("AlsoStale", in: "apps")
    let other = makeRecord("Other", in: "apps")
    let scanner = ApplicationScanner(sources: [source("apps")], scanReport: { _, _ in
        if await calls.nextCall() == 1 { return report([other], unreadable: [cachedStale.bundleURL]) }
        return report([other])
    })
    await scanner.restoreCachedRecords([other], carryForwardOnly: [cachedStale, alsoStale])

    // Not shown before a scan has looked.
    #expect(await ids(scanner) == [other.id])

    await scanner.performFullScan()
    // Kept where the bundle was listed but unreadable, not where it was not listed.
    #expect(await ids(scanner) == [cachedStale.id, other.id])

    // The fallback does not outlive the scan it was kept for.
    await scanner.performFullScan()
    #expect(await ids(scanner) == [other.id])
}

@Test func theEnumerationReportsABundleItCouldNotRead() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let good = root.appendingPathComponent("Good.app/Contents", isDirectory: true)
    let broken = root.appendingPathComponent("Broken.app/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: good, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let plist: [String: Any] = ["CFBundleIdentifier": "example.good", "CFBundleName": "Good", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: good.appendingPathComponent("Info.plist"))

    let result = await ApplicationBundleReader.scanReport(
        source: ApplicationSource(id: "t", rootURL: root, recursive: false, priority: 0)
    )

    guard case .scanned(let records) = result.outcome else {
        Issue.record("the source itself was readable")
        return
    }
    #expect(records.map(\.bundleIdentifier) == ["example.good"])
    #expect(result.unreadableBundles.map(\.lastPathComponent) == ["Broken.app"])
}

@Test func anAppThatIsReallyGoneStillDisappearsWhenNothingFailedToRead() async {
    let calls = Gate()
    let gone = makeRecord("Gone", in: "apps")
    let kept = makeRecord("Kept", in: "apps")
    let scanner = ApplicationScanner(sources: [source("apps")], scanReport: { _, _ in
        if await calls.nextCall() == 1 { return report([gone, kept]) }
        return report([kept])
    })

    await scanner.performFullScan()
    await scanner.performFullScan()

    #expect(await ids(scanner) == [kept.id])
}

@Test func theEnumerationReportsAFolderItCouldNotList() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let locked = root.appendingPathComponent("locked", isDirectory: true)
    try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
    try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: locked.path)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        try? FileManager.default.removeItem(at: root)
    }

    let result = await ApplicationBundleReader.scanReport(
        source: ApplicationSource(id: "t", rootURL: root, recursive: true, priority: 0)
    )

    guard case .scanned = result.outcome else {
        Issue.record("the source itself was readable")
        return
    }
    #expect(result.failedDirectories.map(\.lastPathComponent) == ["locked"])
}

// MARK: Standard sources

/// Terminal, Activity Monitor and Disk Utility are one level below the folder
/// the system source reads.
@Test func theStandardSourcesIncludeTheSystemUtilitiesFolder() throws {
    let utilities = try #require(ApplicationSource.standardSources.first {
        $0.rootURL.path == "/System/Applications/Utilities"
    })
    #expect(utilities.recursive == false)
    #expect(ApplicationSource.standardSources.first { $0.rootURL.path == "/System/Applications" }?.recursive == false)
    #expect(Set(ApplicationSource.standardSources.map(\.id)).count == ApplicationSource.standardSources.count)
}

@Test func aNewAppIsDetectedWithoutRescanningItsSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let apps = root.appendingPathComponent("Apps", isDirectory: true)
    let staging = root.appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = staging.appendingPathComponent("New.app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "example.new", "CFBundleName": "New", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))

    let calls = Gate()
    let scanner = ApplicationScanner(sources: [ApplicationSource(id: "apps", rootURL: apps, recursive: true, priority: 0)], scanReport: { _, _ in
        _ = await calls.nextCall()
        return report([])
    })
    _ = await scanner.performFullScan()
    await scanner.startWatching()
    try await Task.sleep(for: .seconds(1))
    let baseline = await calls.totalCalls
    var updates = await scanner.updates().makeAsyncIterator()
    _ = await updates.next()
    defer { Task { await scanner.stopWatching() } }
    try FileManager.default.moveItem(at: app, to: apps.appendingPathComponent("New.app"))
    for _ in 0..<80 {
        if await scanner.currentSnapshot().records.contains(where: { $0.bundleIdentifier == "example.new" }) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let snapshot = await scanner.currentSnapshot()
    let found = snapshot.records.contains { $0.bundleIdentifier == "example.new" }
    #expect(found)
    if found {
        let update = await updates.next()
        #expect(update?.records.contains { $0.bundleIdentifier == "example.new" } == true)
    }
    #expect(await calls.totalCalls == baseline, "a single new app should not rescan the source")

    try FileManager.default.removeItem(at: apps.appendingPathComponent("New.app"))
    for _ in 0..<80 {
        if await scanner.currentSnapshot().records.isEmpty { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    let removed = await scanner.currentSnapshot().records.isEmpty
    #expect(removed)
    if removed {
        let update = await updates.next()
        #expect(update?.records.isEmpty == true)
    }
    #expect(await calls.totalCalls > baseline, "removal must reconcile the source")
    await scanner.stopWatching()
}

@Test func aNewNestedAppIsDetectedWithoutRescanningItsSource() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let apps = root.appendingPathComponent("Apps", isDirectory: true)
    let nested = apps.appendingPathComponent("Utilities", isDirectory: true)
    let staging = root.appendingPathComponent("Staging", isDirectory: true)
    try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let app = staging.appendingPathComponent("Nested.app", isDirectory: true)
    let contents = app.appendingPathComponent("Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "example.nested", "CFBundleName": "Nested", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    let calls = Gate()
    let scanner = ApplicationScanner(sources: [ApplicationSource(id: "apps", rootURL: apps, recursive: true, priority: 0)], scanReport: { _, _ in
        _ = await calls.nextCall()
        return report([])
    })
    _ = await scanner.performFullScan()
    await scanner.startWatching()
    try await Task.sleep(for: .seconds(1))
    let baseline = await calls.totalCalls
    var updates = await scanner.updates().makeAsyncIterator()
    _ = await updates.next()
    let started = DispatchTime.now().uptimeNanoseconds
    try FileManager.default.moveItem(at: app, to: nested.appendingPathComponent("Nested.app"))
    for _ in 0..<120 {
        if await scanner.currentSnapshot().records.contains(where: { $0.bundleIdentifier == "example.nested" }) { break }
        try await Task.sleep(for: .milliseconds(25))
    }
    let found = await scanner.currentSnapshot().records.contains { $0.bundleIdentifier == "example.nested" }
    let elapsed = DispatchTime.now().uptimeNanoseconds - started
    #expect(found)
    if found {
        let update = await updates.next()
        #expect(update?.records.contains { $0.bundleIdentifier == "example.nested" } == true)
    }
    #expect(await calls.totalCalls == baseline, "a single nested app should not rescan the source")
    print("CATALOG_BENCH scenario=nested-add elapsed_ms=\(Double(elapsed) / 1_000_000)")
    await scanner.stopWatching()
}

@Test func nestedFastPathKeepsHiddenAndNonrecursiveRules() async throws {
    for (folder, recursive) in [(".hidden", true), ("Nested", false)] {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let apps = root.appendingPathComponent("Apps", isDirectory: true)
        let nested = apps.appendingPathComponent(folder, isDirectory: true)
        let staging = root.appendingPathComponent("Staging", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let app = staging.appendingPathComponent("Ignored.app", isDirectory: true)
        let contents = app.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
        let plist: [String: Any] = ["CFBundleIdentifier": "example.ignored", "CFBundleName": "Ignored", "CFBundlePackageType": "APPL"]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0).write(to: contents.appendingPathComponent("Info.plist"))
        let calls = Gate()
        let scanner = ApplicationScanner(sources: [ApplicationSource(id: "apps", rootURL: apps, recursive: recursive, priority: 0)], scanReport: { _, _ in
            _ = await calls.nextCall()
            return report([])
        })
        _ = await scanner.performFullScan()
        await scanner.startWatching()
        try await Task.sleep(for: .seconds(1))
        let baseline = await calls.totalCalls
        try FileManager.default.moveItem(at: app, to: nested.appendingPathComponent("Ignored.app"))
        for _ in 0..<120 {
            if await calls.totalCalls > baseline { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(await calls.totalCalls > baseline)
        #expect(await scanner.currentSnapshot().records.isEmpty)
        await scanner.stopWatching()
    }
}

@Test func watcherCanStopConcurrentlyAfterFileEvents() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    for index in 0..<20 {
        let watcher = try #require(FSEventsWatcher(paths: [root.path], latency: 0.01) { _ in })
        try Data("item".utf8).write(to: root.appendingPathComponent("item\(index)"))
        await withTaskGroup(of: Void.self) { group in
            group.addTask { watcher.stop() }
            group.addTask { watcher.stop() }
        }
    }
}

@Test func filesystemChangesWaitForAnInFlightScan() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let apps = root.appendingPathComponent("Apps", isDirectory: true)
    try FileManager.default.createDirectory(at: apps, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = Gate()
    let source = ApplicationSource(id: "apps", rootURL: apps, recursive: true, priority: 0)
    let scanner = ApplicationScanner(sources: [source], scanReport: { source, known in
        if await gate.nextCall() == 1 { await gate.wait() }
        return await ApplicationBundleReader.scanReport(source: source, knownSignatures: known)
    })
    await scanner.startWatching()
    defer { Task { await scanner.stopWatching() } }
    let initial = Task { await scanner.performFullScan() }
    try await untilWaiting(gate)
    let contents = apps.appendingPathComponent("New.app/Contents", isDirectory: true)
    try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
    let plist: [String: Any] = ["CFBundleIdentifier": "example.queued", "CFBundleName": "Queued", "CFBundlePackageType": "APPL"]
    try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        .write(to: contents.appendingPathComponent("Info.plist"))
    try await Task.sleep(for: .seconds(1))
    #expect(await gate.totalCalls == 1, "filesystem changes must not start concurrent source scans")
    await gate.open()
    _ = await initial.value
    for _ in 0..<80 {
        if await scanner.currentSnapshot().records.contains(where: { $0.bundleIdentifier == "example.queued" }) { break }
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(await scanner.currentSnapshot().records.contains { $0.bundleIdentifier == "example.queued" })
    await scanner.stopWatching()
}
