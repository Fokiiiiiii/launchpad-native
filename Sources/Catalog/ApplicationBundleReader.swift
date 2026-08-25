import Foundation

/// Turns a directory tree into `ApplicationRecord`s. Kept free of any
/// LaunchServices SPI dependency — per `ReverseEngineering/Contracts/launchservices.md`,
/// that Tier 3 API's selectors are not yet verified, so discovery here relies
/// only on `Bundle`, `FileManager`, and the public `Security` framework.
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

    static func scan(
        source: ApplicationSource,
        knownSignatures: [String: KnownSignature] = [:]
    ) -> [ApplicationRecord] {
        let fm = FileManager.default
        var appURLs: [URL] = []

        if source.recursive {
            guard let enumerator = fm.enumerator(
                at: source.rootURL,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles]
            ) else { return [] }
            for case let url as URL in enumerator {
                if url.pathExtension == "app" {
                    appURLs.append(url)
                    enumerator.skipDescendants()
                }
            }
        } else {
            guard let contents = try? fm.contentsOfDirectory(
                at: source.rootURL,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]
            ) else { return [] }
            appURLs = contents.filter { $0.pathExtension == "app" }
        }

        appURLs = appURLs.filter { source.matches(bundleFilename: $0.lastPathComponent) }

        return appURLs.compactMap {
            record(for: $0, sourceID: source.id, knownSignatures: knownSignatures)
        }
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
            iconCacheKey: "\(bundleIdentifier)-\(Int(modDate.timeIntervalSince1970))",
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
