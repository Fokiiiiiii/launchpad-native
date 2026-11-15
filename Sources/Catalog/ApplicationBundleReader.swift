import Foundation

/// Turns a directory tree into `ApplicationRecord`s. Kept free of any
/// LaunchServices SPI dependency — that Tier 3 API's selectors are not
/// verified, so discovery here relies
/// only on `Bundle`, `FileManager`, and the public `Security` framework.
@_silgen_name("launchpad_scan_apps")
private func launchpadScanApps(
    _ path: UnsafePointer<CChar>, _ recursive: Int32, _ context: UnsafeMutableRawPointer,
    _ callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32) -> Void
) -> Int32
enum ApplicationBundleReader {
    /// What a previous scan already learned about a bundle. Reading the code
    /// signature means building a `SecStaticCode` for the bundle, which in a
    /// launch sample was 626ms of the 636ms full scan — essentially all of it,
    /// for ~95 apps that had not changed since the last launch. The
    /// modification date is what makes reuse safe: a bundle that was replaced
    /// or updated gets read again.
    struct KnownSignature: Sendable {
        let modificationDate: Date
        let teamIdentifier: String?

        init(modificationDate: Date, teamIdentifier: String?) {
            self.modificationDate = modificationDate
            self.teamIdentifier = teamIdentifier
        }
    }

    /// What scanning one source produced.
    ///
    /// `unreadable` means the root itself could not be enumerated — a source
    /// on an unmounted volume, a folder that has been deleted, or one this
    /// process is not allowed to read. That is a different fact from "the
    /// folder is there and holds no apps", and collapsing the two is what let
    /// an unplugged drive erase every app it contributed: the scan reported no
    /// records, `pruneMissingItems` read that as "uninstalled", and the pages
    /// and folders were rewritten without them.
    enum ScanOutcome: Sendable {
        case scanned([ApplicationRecord])
        case unreadable
    }

    /// A scan's outcome plus what could not be read on the way.
    ///
    /// A folder inside a readable source that cannot be listed (permissions, a
    /// disconnect mid-walk) is not "no apps here". The enumeration used to skip
    /// it silently, so every app inside it looked uninstalled.
    struct ScanReport: Sendable {
        let outcome: ScanOutcome
        let failedDirectories: [URL]
    }

    private struct BundleListing {
        let appURLs: [URL]
        let failedDirectories: [URL]
    }

    private final class ListingCollector {
        var appURLs: [URL] = []
        var failedDirectories: [URL] = []
    }

    /// Convenience for callers that have nothing to fall back on. An
    /// unreadable source reads as empty here — only use it where that
    /// distinction genuinely does not matter.
    static func scan(
        source: ApplicationSource,
        knownSignatures: [String: KnownSignature] = [:]
    ) async -> [ApplicationRecord] {
        switch await scanOutcome(source: source, knownSignatures: knownSignatures) {
        case .scanned(let records):
            return records
        case .unreadable:
            return []
        }
    }

    static func scanOutcome(
        source: ApplicationSource,
        knownSignatures: [String: KnownSignature] = [:]
    ) async -> ScanOutcome {
        await scanReport(source: source, knownSignatures: knownSignatures).outcome
    }

    static func scanReport(
        source: ApplicationSource,
        knownSignatures: [String: KnownSignature] = [:]
    ) async -> ScanReport {
        guard let listing = bundleListing(in: source) else {
            return ScanReport(outcome: .unreadable, failedDirectories: [])
        }
        let appURLs = listing.appURLs

        // Reading a bundle is independent per app and dominated by
        // `localizedInfoDictionary`, which walks the bundle's resources to
        // resolve the display name. Nothing here mutates shared state, so the
        // bundles are read concurrently; the results are put back in the
        // enumeration's order so a duplicate stable ID still resolves the same
        // way it did when this was a serial pass.
        let sourceID = source.id
        return await withTaskGroup(of: (Int, ApplicationRecord?).self) { group in
            for (index, url) in appURLs.enumerated() {
                group.addTask {
                    (index, record(for: url, sourceID: sourceID, knownSignatures: knownSignatures))
                }
            }
            var byIndex: [Int: ApplicationRecord] = [:]
            for await (index, record) in group {
                if let record { byIndex[index] = record }
            }
            return ScanReport(
                outcome: .scanned(appURLs.indices.compactMap { byIndex[$0] }),
                failedDirectories: listing.failedDirectories
            )
        }
    }

    /// The synchronous walk reports unreadable folders for reconciliation.
    ///
    /// Returns nil when the root cannot be read at all — see `ScanOutcome`.
    private static func bundleListing(in source: ApplicationSource) -> BundleListing? {
        let collector = ListingCollector()
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<CChar>?, Int32) -> Void = { context, path, kind in
            guard let context, let path else { return }
            let collector = Unmanaged<ListingCollector>.fromOpaque(context).takeUnretainedValue()
            let url = URL(fileURLWithFileSystemRepresentation: path, isDirectory: kind != 0, relativeTo: nil)
            if kind == 0 {
                collector.appURLs.append(url)
            } else {
                collector.failedDirectories.append(url)
            }
        }
        let success = source.rootURL.withUnsafeFileSystemRepresentation { path -> Bool in
            guard let path else { return false }
            return launchpadScanApps(path, source.recursive ? 1 : 0, Unmanaged.passUnretained(collector).toOpaque(), callback) != 0
        }
        guard success else { return nil }
        return BundleListing(
            appURLs: collector.appURLs.filter { source.matches(bundleFilename: $0.lastPathComponent) },
            failedDirectories: collector.failedDirectories
        )
    }

    static func record(
        for bundleURL: URL,
        sourceID: String,
        knownSignatures: [String: KnownSignature] = [:]
    ) -> ApplicationRecord? {
        guard let bundle = Bundle(url: bundleURL),
              let bundleIdentifier = bundle.bundleIdentifier else { return nil }

        let info = bundle.infoDictionary ?? [:]
        let localizedInfo = bundle.localizedInfoDictionary ?? [:]

        let originalDisplayName = (info["CFBundleDisplayName"] as? String)
            ?? (info["CFBundleName"] as? String)
            ?? bundleURL.deletingPathExtension().lastPathComponent
        let displayName = (localizedInfo["CFBundleDisplayName"] as? String)
            ?? (localizedInfo["CFBundleName"] as? String)
            ?? originalDisplayName

        let modDate = (try? bundleURL.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? Date(timeIntervalSince1970: 0)

        let known = knownSignatures[signatureCacheKey(for: bundleURL)]
        let teamIdentifier = known?.modificationDate == modDate
            ? known?.teamIdentifier
            : CodeSigningInspector.teamIdentifier(for: bundleURL)
        let id = StableAppID(bundleURL: bundleURL, bundleIdentifier: bundleIdentifier, teamIdentifier: teamIdentifier)

        let executableURL = bundle.executableURL
        let canLaunch = executableURL.map { FileManager.default.isExecutableFile(atPath: $0.path) } ?? false

        // LSUIElement marks a menu-bar/agent app, not necessarily an app that
        // should be dropped from the catalog. Keep it separate from the
        // stronger LSBackgroundOnly flag so tools such as CodexBar remain
        // discoverable while background-only helpers stay filtered.
        let isMenuBarApp = boolish(info["LSUIElement"])
        let isBackgroundOnly = boolish(info["LSBackgroundOnly"])
        let canOpenNewInstance = !boolish(info["LSMultipleInstancesProhibited"])

        return ApplicationRecord(
            id: id,
            bundleIdentifier: bundleIdentifier,
            bundleURL: bundleURL,
            executableURL: executableURL,
            displayName: displayName,
            originalDisplayName: originalDisplayName,
            bundleVersion: (info["CFBundleShortVersionString"] as? String) ?? (info["CFBundleVersion"] as? String),
            teamIdentifier: teamIdentifier,
            category: info["LSApplicationCategoryType"] as? String,
            sourceID: sourceID,
            isSystemProtected: bundleURL.path.hasPrefix("/System/"),
            isBackgroundOnly: isBackgroundOnly,
            isMenuBarApp: isMenuBarApp,
            // The identifier alone is shared by every copy of an app, and so was
            // the picture — two copies with the same modification second drew
            // each other's icon. The path-derived part tells them apart.
            iconCacheKey: "\(bundleIdentifier)-\(Int(modDate.timeIntervalSince1970))-\(id.value.prefix(12))",
            canLaunch: canLaunch,
            canOpenNewInstance: canOpenNewInstance,
            lastSeenModificationDate: modDate
        )
    }

    /// Matches how `StableAppID` normalizes a bundle path, so a record read
    /// back from a snapshot lines up with the same bundle on disk.
    static func signatureCacheKey(for bundleURL: URL) -> String {
        bundleURL.standardizedFileURL.path
    }

    private static func boolish(_ value: Any?) -> Bool {
        switch value {
        case let b as Bool: return b
        case let n as NSNumber: return n.boolValue
        case let s as String: return (s as NSString).boolValue
        default: return false
        }
    }
}
