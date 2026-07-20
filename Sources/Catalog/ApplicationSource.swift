import Foundation

/// A directory tree the scanner looks for `.app` bundles in. Standard sources
/// ship built in; Phase 6 adds user-configurable custom sources on top of
/// this same type (recursive flag, include/exclude globs, priority).
public struct ApplicationSource: Hashable, Sendable {
    public let id: String
    public let rootURL: URL
    public let recursive: Bool
    public let priority: Int

    public init(id: String, rootURL: URL, recursive: Bool, priority: Int) {
        self.id = id
        self.rootURL = rootURL
        self.recursive = recursive
        self.priority = priority
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
