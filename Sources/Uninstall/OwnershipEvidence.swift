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

import CLaunchpadCore

private final class DirectorySelection {
    let directory: URL
    let matches: (String) -> Bool
    var entries: [URL] = []

    init(directory: URL, matches: @escaping (String) -> Bool) {
        self.directory = directory
        self.matches = matches
    }
}

private final class ReceiptSelection {
    let bundleID: String
    var entries: [String] = []

    init(bundleID: String) { self.bundleID = bundleID }
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

        // The identifier comes from the app's own Info.plist and is about to be
        // pasted into paths under ~/Library. One with a slash or a ".." in it
        // would point those paths at something that is not this app's data —
        // and the plan pre-checks what it finds. No related paths at all is
        // the safe answer; the app itself can still be removed.
        guard BundleIdentifier.isSafeFileName(bundleID) else {
            DiagnosticsLog.uninstall.error("Refusing to look for data of an app whose bundle identifier is not a plain file name")
            return OwnershipEvidence(
                bundleURL: record.bundleURL,
                relatedPaths: [],
                userLaunchAgents: [],
                systemLaunchItems: [],
                receiptPackageIDs: [],
                systemExtensionIdentifiers: []
            )
        }

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
            matchingBundleID: bundleID,
            verifyingLabel: true
        )
        let systemLaunchItems = launchItems(in: URL(fileURLWithPath: "/Library/LaunchAgents"), matchingBundleID: bundleID, verifyingLabel: false)
            + launchItems(in: URL(fileURLWithPath: "/Library/LaunchDaemons"), matchingBundleID: bundleID, verifyingLabel: false)

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

    static func directoryEntries(in directory: URL, matching: (String) -> Bool) -> [URL] {
        withoutActuallyEscaping(matching) { matches in
            guard (try? directory.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false else {
                return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { matches($0.lastPathComponent) }) ?? []
            }
            let resolved = directory.withUnsafeFileSystemRepresentation { path -> URL? in
                guard let path, let canonical = realpath(path, nil) else { return nil }
                defer { free(canonical) }
                return URL(fileURLWithFileSystemRepresentation: canonical, isDirectory: true, relativeTo: nil)
            }
            guard let resolved else {
                return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { matches($0.lastPathComponent) }) ?? []
            }
            let selection = DirectorySelection(directory: resolved, matches: matches)
            let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void = { context, bytes, count in
                guard let context, let bytes, let length = Int(exactly: count) else { return }
                let selection = Unmanaged<DirectorySelection>.fromOpaque(context).takeUnretainedValue()
                let name = String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
                if selection.matches(name) { selection.entries.append(selection.directory.appendingPathComponent(name)) }
            }
            let status = resolved.withUnsafeFileSystemRepresentation { path in
                launchpad_directory_entries(path, Unmanaged.passUnretained(selection).toOpaque(), callback)
            }
            if status == 1 { return selection.entries }
            return (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { matches($0.lastPathComponent) }) ?? []
        }
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
        directoryEntries(in: directory, matching: matching)
            .map { RelatedPath(url: $0, category: category, exists: true) }
    }

    /// Whether `name` is the identifier itself or one of its dotted children —
    /// `com.example.app` and `com.example.app.helper`, but not `com.example.app2`
    /// or `com.example.appstore`, which a plain prefix test would also take.
    static func isOwnName(_ name: String, bundleID: String) -> Bool {
        name == bundleID || name.hasPrefix(bundleID + ".")
    }

    /// Scans a LaunchAgents/LaunchDaemons directory for `.plist` files named
    /// after the target bundle identifier — the common real-world convention
    /// (e.g. `com.example.app.helper.plist` for `com.example.app`), not a
    /// guaranteed mapping.
    ///
    /// With `verifyingLabel`, the plist's own `Label` has to follow the same
    /// rule: the Label is what gets unloaded from launchd before the file is
    /// trashed, so a file whose name matches but whose Label names another
    /// product's job must not be taken.
    static func launchItems(in directory: URL, matchingBundleID bundleID: String, verifyingLabel: Bool) -> [URL] {
        return directoryEntries(in: directory, matching: { $0.hasSuffix(".plist") }).filter { entry in
            guard entry.pathExtension == "plist",
                  isOwnName(entry.deletingPathExtension().lastPathComponent, bundleID: bundleID) else {
                return false
            }
            guard verifyingLabel else { return true }
            guard let data = try? Data(contentsOf: entry),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                  let label = plist["Label"] as? String else {
                return false
            }
            return isOwnName(label, bundleID: bundleID)
        }
    }

    /// `pkgutil --pkgs` lists installed package receipt identifiers; this is
    /// the public CLI tool, not a private framework — a plain `Process`
    /// invocation, read-only.
    static func receipts(matchingBundleID bundleID: String, program: String = "/usr/sbin/pkgutil") -> [String] {
        let selection = ReceiptSelection(bundleID: bundleID)
        let callback: @convention(c) (UnsafeMutableRawPointer?, UnsafePointer<UInt8>?, UInt) -> Void = { context, bytes, count in
            guard let context, let bytes, let length = Int(exactly: count) else { return }
            let selection = Unmanaged<ReceiptSelection>.fromOpaque(context).takeUnretainedValue()
            let line = String(decoding: UnsafeBufferPointer(start: bytes, count: length), as: UTF8.self)
            if line.contains(selection.bundleID) { selection.entries.append(line) }
        }
        let status = program.withCString { launchpad_receipt_lines($0, Unmanaged.passUnretained(selection).toOpaque(), callback) }
        guard status == 1 else {
            DiagnosticsLog.uninstall.error("Failed to read package receipt identifiers")
            return []
        }
        return selection.entries
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

}
