import Darwin
import Foundation

/// A directory tree the scanner looks for `.app` bundles in. Standard sources
/// ship built in; Phase 6 custom sources use this same type with
/// recursive/priority plus optional include/exclude globs matched against
/// the bundle's filename (e.g. `*.app`, `Beta*`).
public struct ApplicationSource: Hashable, Sendable {
    public let id: String
    public let rootURL: URL
    public let recursive: Bool
    public let priority: Int
    public let includeGlobs: [String]
    public let excludeGlobs: [String]

    public init(
        id: String,
        rootURL: URL,
        recursive: Bool,
        priority: Int,
        includeGlobs: [String] = [],
        excludeGlobs: [String] = []
    ) {
        self.id = id
        self.rootURL = rootURL
        self.recursive = recursive
        self.priority = priority
        self.includeGlobs = includeGlobs
        self.excludeGlobs = excludeGlobs
    }

    /// True if this bundle's filename passes the include/exclude glob
    /// filters (empty `includeGlobs` means "everything included").
    public func matches(bundleFilename: String) -> Bool {
        if !excludeGlobs.isEmpty, excludeGlobs.contains(where: { Self.matchesGlob($0, bundleFilename) }) {
            return false
        }
        guard !includeGlobs.isEmpty else { return true }
        return includeGlobs.contains { Self.matchesGlob($0, bundleFilename) }
    }

    private static func matchesGlob(_ pattern: String, _ name: String) -> Bool {
        fnmatch(pattern, name, 0) == 0
    }

    public static let standardSources: [ApplicationSource] = [
        ApplicationSource(id: "system", rootURL: URL(fileURLWithPath: "/System/Applications"), recursive: false, priority: 0),
        ApplicationSource(id: "applications", rootURL: URL(fileURLWithPath: "/Applications"), recursive: true, priority: 10),
        ApplicationSource(
            id: "user",
            rootURL: FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
            recursive: true,
            priority: 20
        )
    ]
}
