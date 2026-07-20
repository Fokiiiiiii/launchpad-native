import Catalog
import Diagnostics
import Foundation

/// One filesystem path discovered as plausibly belonging to an app, along
/// with why it was found — kept separate from the classification decision
/// (`RemovalPlanner`) so evidence-gathering stays a pure read/observe step.
public struct RelatedPath: Sendable, Equatable {
    public enum Category: Sendable {
        case applicationSupport
        case caches
        case preferences
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

        var relatedPaths: [RelatedPath] = []
        let appSupport = home.appendingPathComponent("Library/Application Support/\(bundleID)")
        relatedPaths.append(RelatedPath(url: appSupport, category: .applicationSupport, exists: fm.fileExists(atPath: appSupport.path)))
        let caches = home.appendingPathComponent("Library/Caches/\(bundleID)")
        relatedPaths.append(RelatedPath(url: caches, category: .caches, exists: fm.fileExists(atPath: caches.path)))
        let prefs = home.appendingPathComponent("Library/Preferences/\(bundleID).plist")
        relatedPaths.append(RelatedPath(url: prefs, category: .preferences, exists: fm.fileExists(atPath: prefs.path)))

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
