import Foundation
import Testing
@testable import Catalog

/// Holds a scan open until the test lets it finish, and says when a scan has
/// reached the hold, so the test can interleave other work deterministically.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var callCount = 0

    var waitingCount: Int { waiters.count }

    func nextCall() -> Int {
        callCount += 1
        return callCount
    }

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

private func report(_ records: [ApplicationRecord], failed: [URL] = []) -> ApplicationBundleReader.ScanReport {
    ApplicationBundleReader.ScanReport(outcome: .scanned(records), failedDirectories: failed)
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
