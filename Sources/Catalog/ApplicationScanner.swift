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
        public static let empty = Snapshot(recordsByID: [:])
    }

    private var snapshot: Snapshot = .empty
    private let sources: [ApplicationSource]
    private var watcher: FSEventsWatcher?
    private var continuations: [UUID: AsyncStream<Snapshot>.Continuation] = [:]

    public init(sources: [ApplicationSource] = ApplicationSource.standardSources) {
        self.sources = sources
    }

    public func currentSnapshot() -> Snapshot { snapshot }

    /// Full scan of every configured source, merged by stable ID. Higher
    /// `priority` sources win when a duplicate stable ID is somehow produced
    /// by two sources (should be rare since identity includes the resolved
    /// path, but overlapping source roots make it possible).
    @discardableResult
    public func performFullScan() -> Snapshot {
        var merged: [StableAppID: ApplicationRecord] = [:]
        for source in sources.sorted(by: { $0.priority < $1.priority }) {
            for record in ApplicationBundleReader.scan(source: source) {
                merged[record.id] = record
            }
        }
        snapshot = Snapshot(recordsByID: merged)
        DiagnosticsLog.catalog.info("Full scan complete: \(merged.count, privacy: .public) applications across \(self.sources.count, privacy: .public) sources")
        broadcast()
        return snapshot
    }

    /// Starts watching all source roots for filesystem changes. Each event
    /// triggers a rescan of only the affected source(s), not the whole
    /// catalog.
    public func startWatching() {
        guard watcher == nil else { return }
        let roots = sources.map { $0.rootURL.path }
        watcher = FSEventsWatcher(paths: roots) { [weak self] changedPaths in
            guard let self else { return }
            Task { await self.handleChanges(changedPaths) }
        }
        if watcher == nil {
            DiagnosticsLog.catalog.error("FSEventsWatcher failed to start; catalog will only update on explicit rescans")
        }
    }

    public func stopWatching() {
        watcher = nil
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
        let affectedSources = sources.filter { source in
            changedPaths.contains { $0.hasPrefix(source.rootURL.path) }
        }
        guard !affectedSources.isEmpty else { return }

        var merged = snapshot.recordsByID
        for source in affectedSources {
            merged = merged.filter { $0.value.sourceID != source.id }
            for record in ApplicationBundleReader.scan(source: source) {
                merged[record.id] = record
            }
        }
        snapshot = Snapshot(recordsByID: merged)
        DiagnosticsLog.catalog.info("Incremental rescan of \(affectedSources.count, privacy: .public) source(s) after filesystem change")
        broadcast()
    }
}
