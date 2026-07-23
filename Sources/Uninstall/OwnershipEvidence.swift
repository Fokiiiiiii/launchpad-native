import Catalog
import Diagnostics
import Foundation

/// One filesystem path discovered as plausibly belonging to an app, along
/// with why it was found — kept separate from the classification decision
/// (`RemovalPlanner`) so evidence-gathering stays a pure read/observe step.
public struct RelatedPath: Sendable, Equatable {
    public enum Category: Sendable, Hashable {
        case applicationSupport
        case caches
        case preferences
        case preferencesByHost
        /// Sandboxed app container (`~/Library/Containers/<bundleID>`) —
        /// mirrors the app's own Application Support/Preferences/Caches
        /// inside a sandbox, so it's a separate location entirely.
        case containers
        /// App Group container (`~/Library/Group Containers`) — shared **by
        /// design** across every app in the same group, so `RemovalPlanner`
        /// always classifies this as `.sharedRisk` regardless of the
        /// same-team-sibling check used for everything else.
        case groupContainers
        case savedApplicationState
        case webKit
        case httpStorages
        case cookies
        case logs
        case applicationScripts
    }

    public let url: URL
    public let category: Category
    public let exists: Bool

    public init(url: URL, category: Category, exists: Bool) {
        self.url = url
        self.category = category
        self.exists = exists
    }
}

/// Everything discovered about one installed app that removal decisions
/// depend on. Collection is read-only: no file is moved, deleted, or
/// modified, and no privileged process is started.
public struct OwnershipEvidence: Sendable {
    public let bundleURL: URL
    public let relatedPaths: [RelatedPath]
    public let userLaunchAgents: [URL]
    public let systemLaunchItems: [URL]
    public let receiptPackageIDs: [String]
    public let systemExtensionIdentifiers: [String]

    public init(
        bundleURL: URL,
        relatedPaths: [RelatedPath],
        userLaunchAgents: [URL],
        systemLaunchItems: [URL],
        receiptPackageIDs: [String],
        systemExtensionIdentifiers: [String]
    ) {
        self.bundleURL = bundleURL
        self.relatedPaths = relatedPaths
        self.userLaunchAgents = userLaunchAgents
        self.systemLaunchItems = systemLaunchItems
        self.receiptPackageIDs = receiptPackageIDs
        self.systemExtensionIdentifiers = systemExtensionIdentifiers
    }
}

/// Gathers ownership evidence for one `ApplicationRecord`. Every step here is
/// read-only: existence checks, directory listings, and `pkgutil` queries
/// (a public CLI tool, not a private API) — nothing is ever deleted, moved,
/// or written by this type.
public enum OwnershipEvidenceCollector {
    public static func collect(for record: ApplicationRecord) -> OwnershipEvidence {
        let fm = FileManager.default
        let home = fm.homeDirectoryForCurrentUser
        let bundleID = record.bundleIdentifier

        // Every well-known location a macOS app can leave data in, beyond
        // the "big three" (Application Support/Caches/Preferences) —
        // sandboxed containers, WebKit/cookie storage, saved window state,
        // per-host prefs, and (deliberately last, since it needs its own
        // sharedRisk-by-design rule) Group Containers. All of these are
        // strictly under the user's own home directory — nothing here needs
        // root, matching the rest of this phase's non-privileged scope.
        var relatedPaths: [RelatedPath] = [
            singlePath(home.appendingPathComponent("Library/Application Support/\(bundleID)"), category: .applicationSupport),
            singlePath(home.appendingPathComponent("Library/Caches/\(bundleID)"), category: .caches),
            singlePath(home.appendingPathComponent("Library/Preferences/\(bundleID).plist"), category: .preferences),
            singlePath(home.appendingPathComponent("Library/Containers/\(bundleID)"), category: .containers),
            singlePath(home.appendingPathComponent("Library/Saved Application State/\(bundleID).savedState"), category: .savedApplicationState),
            singlePath(home.appendingPathComponent("Library/WebKit/\(bundleID)"), category: .webKit),
            singlePath(home.appendingPathComponent("Library/HTTPStorages/\(bundleID)"), category: .httpStorages),
            singlePath(home.appendingPathComponent("Library/Cookies/\(bundleID).binarycookies"), category: .cookies),
            singlePath(home.appendingPathComponent("Library/Logs/\(bundleID)"), category: .logs),
            singlePath(home.appendingPathComponent("Library/Application Scripts/\(bundleID)"), category: .applicationScripts)
        ]

        relatedPaths += matchingDirectoryEntries(
            in: home.appendingPathComponent("Library/Preferences/ByHost"),
            matching: { $0.hasPrefix("\(bundleID).") },
            category: .preferencesByHost
        )
        relatedPaths += matchingDirectoryEntries(
            in: home.appendingPathComponent("Library/Group Containers"),
            matching: { $0.contains(bundleID) },
            category: .groupContainers
        )

        let userLaunchAgents = launchItems(
            in: home.appendingPathComponent("Library/LaunchAgents"),
            matchingBundleID: bundleID
        )
        let systemLaunchItems = launchItems(in: URL(fileURLWithPath: "/Library/LaunchAgents"), matchingBundleID: bundleID)
            + launchItems(in: URL(fileURLWithPath: "/Library/LaunchDaemons"), matchingBundleID: bundleID)

        let receiptPackageIDs = receipts(matchingBundleID: bundleID)
        let systemExtensionIdentifiers = extensionIdentifiers(in: record.bundleURL)

        return OwnershipEvidence(
            bundleURL: record.bundleURL,
            relatedPaths: relatedPaths,
            userLaunchAgents: userLaunchAgents,
            systemLaunchItems: systemLaunchItems,
            receiptPackageIDs: receiptPackageIDs,
            systemExtensionIdentifiers: systemExtensionIdentifiers
        )
    }

    private static func singlePath(_ url: URL, category: RelatedPath.Category) -> RelatedPath {
        RelatedPath(url: url, category: category, exists: FileManager.default.fileExists(atPath: url.path))
    }

    /// Scans a directory (ByHost prefs, Group Containers) for entries whose
    /// filename satisfies `matching`, returning one `RelatedPath` per match
    /// — unlike the fixed single-path locations above, these don't have a
    /// filename that's exactly the bundle identifier.
    private static func matchingDirectoryEntries(
        in directory: URL,
        matching: (String) -> Bool,
        category: RelatedPath.Category
    ) -> [RelatedPath] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries
            .filter { matching($0.lastPathComponent) }
            .map { RelatedPath(url: $0, category: category, exists: true) }
    }

    /// Scans a LaunchAgents/LaunchDaemons directory for `.plist` files whose
    /// `Label` contains the target bundle identifier — the common real-world
    /// naming convention (e.g. `com.example.app.helper.plist` for
    /// `com.example.app`), not a guaranteed mapping.
    private static func launchItems(in directory: URL, matchingBundleID bundleID: String) -> [URL] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: nil
        ) else { return [] }
        return entries.filter { $0.pathExtension == "plist" && $0.deletingPathExtension().lastPathComponent.hasPrefix(bundleID) }
    }

    /// `pkgutil --pkgs` lists installed package receipt identifiers; this is
    /// the public CLI tool, not a private framework — a plain `Process`
    /// invocation, read-only.
    private static func receipts(matchingBundleID bundleID: String) -> [String] {
        guard let output = runProcess("/usr/sbin/pkgutil", ["--pkgs"]) else { return [] }
        return output
            .split(separator: "\n")
            .map(String.init)
            .filter { $0.contains(bundleID) }
    }

    /// Extensions are declared in a bundle's own Info.plist under the
    /// `NSExtension` key; this only reads the plist already on disk — it
    /// does not query `systemextensionsctl` or check activation state
    /// (that belongs to the execution step, not evidence collection).
    private static func extensionIdentifiers(in bundleURL: URL) -> [String] {
        guard let bundle = Bundle(url: bundleURL) else { return [] }
        var identifiers: [String] = []
        if let identifier = bundle.bundleIdentifier {
            if bundle.infoDictionary?["NSExtension"] != nil {
                identifiers.append(identifier)
            }
        }
        return identifiers
    }

    private static func runProcess(_ path: String, _ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            DiagnosticsLog.uninstall.error("Failed to run \(path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
