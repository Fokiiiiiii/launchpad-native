import Diagnostics
import Foundation

/// Owns the live application catalog. A full scan only happens on init and
/// when explicitly requested; day-to-day updates come from `FSEventsWatcher`
/// rescanning just the affected source, not the whole catalog — satisfying
/// "no full scan on every launcher open."
public actor ApplicationScanner {
    public struct Snapshot: Sendable {
        public var recordsByID: [StableAppID: ApplicationRecord]
        public var records: [ApplicationRecord] { Array(recordsByID.values) }

        public init(recordsByID: [StableAppID: ApplicationRecord]) {
            self.recordsByID = recordsByID
        }

        public static let empty = Snapshot(recordsByID: [:])
    }

    private var snapshot: Snapshot = .empty
    private var sources: [ApplicationSource]
    private var watcher: FSEventsWatcher?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]
    private var pendingChangedPaths: Set<String> = []
    private var debounceTask: Task<Void, Never>?
    private let changeDebounceNanoseconds: UInt64 = 200_000_000
    /// Numbers each scan as it starts, and records per source the newest one
    /// whose result was accepted — see `integrate`.
    private var nextScanToken = 0
    private var lastAcceptedToken: [String: Int] = [:]
    private let scanReport: @Sendable (ApplicationSource, [String: ApplicationBundleReader.KnownSignature]) async -> ApplicationBundleReader.ScanReport

    public init(sources: [ApplicationSource] = ApplicationSource.standardSources) {
        self.sources = sources
        self.scanReport = { source, known in
            await ApplicationBundleReader.scanReport(source: source, knownSignatures: known)
        }
    }

    /// `scanReport` is a parameter so a test can hold a scan open and finish it
    /// after another has already been accepted.
    init(
        sources: [ApplicationSource],
        scanReport: @escaping @Sendable (ApplicationSource, [String: ApplicationBundleReader.KnownSignature]) async -> ApplicationBundleReader.ScanReport
    ) {
        self.sources = sources
        self.scanReport = scanReport
    }

    public func currentSnapshot() -> Snapshot { snapshot }

    /// Restores only the cheap, last-known-good records needed for the first
    /// frame. The next full scan remains authoritative and reconciles any
    /// stale metadata or missing bundles in the background.
    public func restoreCachedRecords(_ records: [ApplicationRecord]) {
        var merged: [StableAppID: ApplicationRecord] = [:]
        for record in records {
            merged[record.id] = record
        }
        guard merged != snapshot.recordsByID else { return }
        snapshot = Snapshot(recordsByID: merged)
        DiagnosticsLog.catalog.info(
            "Catalog snapshot accepted: \(merged.count, privacy: .public) records"
        )
        broadcast()
    }

    /// Full scan of every configured source, merged by stable ID. Higher
    /// priority sources win when a duplicate stable ID is somehow produced
    /// by two sources (should be rare since identity includes the resolved
    /// path, but overlapping source roots make it possible).
    @discardableResult
    public func performFullScan() async -> Snapshot {
        let start = DispatchTime.now()
        nextScanToken += 1
        let token = nextScanToken
        let known = knownSignatures()
        var reports: [(source: ApplicationSource, report: ApplicationBundleReader.ScanReport)] = []
        for source in sources.sorted(by: { $0.priority < $1.priority }) {
            reports.append((source, await scanReport(source, known)))
        }
        let changed = integrate(reports, token: token)
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        DiagnosticsLog.catalog.info(
            "Full scan complete: \(self.snapshot.recordsByID.count, privacy: .public) applications across \(self.sources.count, privacy: .public) sources in \(ms, privacy: .public)ms"
        )
        if changed {
            broadcast()
        }
        return snapshot
    }

    /// Folds scan results into the snapshot.
    ///
    /// Awaiting a scan lets other work run on this actor — a change of sources,
    /// a newer scan — so by the time the results arrive they may describe a
    /// source that is no longer configured, or be older than what has already
    /// been accepted for it. Taking them anyway let a slow scan of the old
    /// configuration put back apps the user had just removed, and the grid then
    /// pruned and saved on that. Each source's result is accepted only when its
    /// source is still configured and the scan started after the last one
    /// accepted for it; everything else keeps what the snapshot has now.
    ///
    /// Returns whether the snapshot changed.
    private func integrate(
        _ reports: [(source: ApplicationSource, report: ApplicationBundleReader.ScanReport)],
        token: Int
    ) -> Bool {
        let configured = Set(sources.map(\.id))
        let fresh = reports
            .filter { configured.contains($0.source.id) && token > (lastAcceptedToken[$0.source.id] ?? 0) }
            .sorted { $0.source.priority < $1.source.priority }
        let freshIDs = Set(fresh.map { $0.source.id })

        var merged = snapshot.recordsByID.filter {
            configured.contains($0.value.sourceID) && !freshIDs.contains($0.value.sourceID)
        }
        for (source, report) in fresh {
            lastAcceptedToken[source.id] = token
            switch report.outcome {
            case .scanned(let records):
                for record in records {
                    merged[record.id] = record
                }
                // Folders that could not be listed say nothing about the apps in
                // them, so what was known there stays.
                if !report.failedDirectories.isEmpty {
                    carryForward(source: source, into: &merged, within: report.failedDirectories)
                }
            case .unreadable:
                carryForward(source: source, into: &merged, within: nil)
            }
        }
        guard merged != snapshot.recordsByID else { return false }
        snapshot = Snapshot(recordsByID: merged)
        return true
    }

    /// Keeps whatever a source last contributed when this scan could not read
    /// it.
    ///
    /// A scan result is authoritative: subscribers hand it to
    /// `GridModel.pruneMissingItems`, which removes anything missing from the
    /// user's pages and folders and saves. So a source that momentarily cannot
    /// be enumerated — an ejected drive, a network mount that is down — must
    /// not arrive as "every app in it was uninstalled". Carrying the previous
    /// records forward keeps the catalog honest until the source is readable
    /// again, and a genuinely deleted app still disappears the moment its
    /// source can be read and no longer lists it.
    ///
    /// With `directories`, only what was known inside those folders is kept —
    /// the rest of the source was read fine and is taken from this scan.
    private func carryForward(
        source: ApplicationSource,
        into merged: inout [StableAppID: ApplicationRecord],
        within directories: [URL]?
    ) {
        let carried = snapshot.recordsByID.values.filter { record in
            guard record.sourceID == source.id, merged[record.id] == nil else { return false }
            guard let directories else { return true }
            return directories.contains { isPath(record.bundleURL.path, inside: $0) }
        }
        for record in carried {
            merged[record.id] = record
        }
        DiagnosticsLog.catalog.error(
            "Source \(source.id, privacy: .public) could not be read; kept \(carried.count, privacy: .public) previously known records rather than reporting them uninstalled"
        )
    }

    /// What the current snapshot — restored from disk at launch, or left by
    /// an earlier scan — already knows about each bundle's code signature.
    private func knownSignatures() -> [String: ApplicationBundleReader.KnownSignature] {
        var known: [String: ApplicationBundleReader.KnownSignature] = [:]
        known.reserveCapacity(snapshot.recordsByID.count)
        for record in snapshot.recordsByID.values {
            known[ApplicationBundleReader.signatureCacheKey(for: record.bundleURL)] =
                ApplicationBundleReader.KnownSignature(
                    modificationDate: record.lastSeenModificationDate,
                    teamIdentifier: record.teamIdentifier
                )
        }
        return known
    }

    /// Starts watching all source roots for filesystem changes. Each event is
    /// coalesced by a short debounce before only the affected source(s) are
    /// incrementally rescanned.
    public func startWatching() {
        guard watcher == nil else { return }
        let roots = sources.map { $0.rootURL.path }
        watcher = FSEventsWatcher(paths: roots) { [weak self] changedPaths in
            guard let self else { return }
            Task { await self.handleChanges(changedPaths) }
        }
        if watcher == nil {
            DiagnosticsLog.catalog.error(
                "FSEventsWatcher failed to start; catalog will only update on explicit rescans"
            )
        }
    }

    func stopWatching() {
        watcher?.stop()
        watcher = nil
        debounceTask?.cancel()
        debounceTask = nil
        pendingChangedPaths.removeAll()
    }

    /// Replaces the configured roots after a Settings change. Existing
    /// watchers are torn down before the first scan so removed folders cannot
    /// continue emitting stale events; subscribers receive the rebuilt
    /// snapshot through the normal update stream.
    public func replaceSources(_ newSources: [ApplicationSource]) async {
        let wasWatching = watcher != nil
        stopWatching()
        sources = newSources
        _ = await performFullScan()
        if wasWatching {
            startWatching()
        }
    }

    /// Subscribe to catalog snapshots. Yields immediately with the current
    /// snapshot, then again whenever a scan changes it.
    public func updates() -> AsyncStream<Snapshot> {
        let id = UUID()
        let current = snapshot
        return AsyncStream { continuation in
            continuation.yield(current)
            continuations[id] = continuation
            continuation.onTermination = { [weak self] _ in
                guard let self else { return }
                Task { await self.removeContinuation(id) }
            }
        }
    }

    private func removeContinuation(_ id: UUID) {
        continuations.removeValue(forKey: id)
    }

    private func broadcast() {
        for continuation in continuations.values {
            continuation.yield(snapshot)
        }
    }

    private func handleChanges(_ changedPaths: [String]) {
        pendingChangedPaths.formUnion(changedPaths)
        guard debounceTask == nil else { return }

        let delay = changeDebounceNanoseconds
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled else { return }
            await self?.flushPendingChanges()
        }
    }

    private func flushPendingChanges() async {
        debounceTask = nil
        let changedPaths = Array(pendingChangedPaths)
        pendingChangedPaths.removeAll()
        guard !changedPaths.isEmpty else { return }

        let affectedSources = sources.filter { source in
            changedPaths.contains { path in
                isPath(path, inside: source.rootURL)
            }
        }
        guard !affectedSources.isEmpty else { return }

        nextScanToken += 1
        let token = nextScanToken
        let known = knownSignatures()
        var reports: [(source: ApplicationSource, report: ApplicationBundleReader.ScanReport)] = []
        for source in affectedSources {
            reports.append((source, await scanReport(source, known)))
        }
        guard integrate(reports, token: token) else { return }
        DiagnosticsLog.catalog.info(
            "Incremental rescan of \(affectedSources.count, privacy: .public) source(s) after filesystem change"
        )
        broadcast()
    }

    private func isPath(_ changedPath: String, inside rootURL: URL) -> Bool {
        let root = rootURL.standardizedFileURL.resolvingSymlinksInPath().path
        let changed = URL(fileURLWithPath: changedPath)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
        if changed == root { return true }
        // A separator boundary avoids treating /ApplicationsOther as a
        // descendant of /Applications. The filesystem root is the one case
        // where every absolute path is a valid descendant.
        return root == "/" ? changed.hasPrefix("/") : changed.hasPrefix(root + "/")
    }
}
