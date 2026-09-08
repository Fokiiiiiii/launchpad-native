import Foundation
import Testing
@testable import Catalog

@Test func fullScanMergesMultipleSourcesAndHigherPriorityWins() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let lowDir = tempDir.appendingPathComponent("low")
    let highDir = tempDir.appendingPathComponent("high")
    try FileManager.default.createDirectory(at: lowDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: highDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    func makeApp(named name: String, id: String, in dir: URL) throws {
        let bundleURL = dir.appendingPathComponent("\(name).app")
        let macOS = bundleURL.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": id, "CFBundleName": name, "CFBundleExecutable": name
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        try Data().write(to: macOS.appendingPathComponent(name))
    }

    try makeApp(named: "OnlyLow", id: "com.example.low", in: lowDir)
    try makeApp(named: "OnlyHigh", id: "com.example.high", in: highDir)

    let sources = [
        ApplicationSource(id: "low", rootURL: lowDir, recursive: false, priority: 0),
        ApplicationSource(id: "high", rootURL: highDir, recursive: false, priority: 10)
    ]
    let scanner = ApplicationScanner(sources: sources)
    let snapshot = await scanner.performFullScan()

    #expect(snapshot.records.count == 2)
    #expect(Set(snapshot.records.map(\.bundleIdentifier)) == ["com.example.low", "com.example.high"])
}

@Test func updatesStreamYieldsCurrentSnapshotImmediately() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let scanner = ApplicationScanner(sources: [
        ApplicationSource(id: "empty", rootURL: tempDir, recursive: false, priority: 0)
    ])
    await scanner.performFullScan()

    var iterator = await scanner.updates().makeAsyncIterator()
    let first = await iterator.next()
    #expect(first?.records.isEmpty == true)
}


@Test func replacingSourcesRebuildsCatalogWithoutRelaunch() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let emptyDir = tempDir.appendingPathComponent("empty")
    let appsDir = tempDir.appendingPathComponent("apps")
    try FileManager.default.createDirectory(at: emptyDir, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: appsDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let bundleURL = appsDir.appendingPathComponent("Dynamic.app")
    let macOS = bundleURL.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "com.example.dynamic",
        "CFBundleName": "Dynamic",
        "CFBundleExecutable": "Dynamic"
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    try Data().write(to: macOS.appendingPathComponent("Dynamic"))

    let scanner = ApplicationScanner(sources: [
        ApplicationSource(id: "empty", rootURL: emptyDir, recursive: false, priority: 0)
    ])
    #expect((await scanner.performFullScan()).records.isEmpty)

    await scanner.replaceSources([
        ApplicationSource(id: "apps", rootURL: appsDir, recursive: false, priority: 0)
    ])
    let snapshot = await scanner.currentSnapshot()
    #expect(snapshot.records.map(\.bundleIdentifier) == ["com.example.dynamic"])
}

/// An ejected drive, a deleted folder, or a root this process cannot read must
/// not be reported as "every app here was uninstalled" — that result reaches
/// `GridModel.pruneMissingItems`, which rewrites the user's pages and folders
/// and saves.
@Test func aSourceThatCannotBeReadIsDistinguishedFromAnEmptyOne() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let emptyButPresent = ApplicationSource(id: "present", rootURL: tempDir, recursive: false, priority: 0)
    switch await ApplicationBundleReader.scanOutcome(source: emptyButPresent) {
    case .scanned(let records):
        #expect(records.isEmpty)
    case .unreadable:
        Issue.record("a readable, empty directory was reported unreadable")
    }

    let gone = ApplicationSource(
        id: "gone",
        rootURL: tempDir.appendingPathComponent("no-such-folder"),
        recursive: false,
        priority: 0
    )
    switch await ApplicationBundleReader.scanOutcome(source: gone) {
    case .scanned:
        Issue.record("a missing root was reported as a successful scan of zero apps")
    case .unreadable:
        break
    }

    // Recursive sources take a different branch of the enumeration.
    let goneRecursive = ApplicationSource(
        id: "gone-recursive",
        rootURL: tempDir.appendingPathComponent("no-such-folder"),
        recursive: true,
        priority: 0
    )
    switch await ApplicationBundleReader.scanOutcome(source: goneRecursive) {
    case .scanned:
        Issue.record("a missing recursive root was reported as a successful scan of zero apps")
    case .unreadable:
        break
    }
}

@Test func rescanningAnUnreadableSourceKeepsWhatItLastContributed() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let volumeDir = tempDir.appendingPathComponent("removable")
    try FileManager.default.createDirectory(at: volumeDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let bundleURL = volumeDir.appendingPathComponent("Portable.app")
    let macOS = bundleURL.appendingPathComponent("Contents/MacOS")
    try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
    let info: [String: Any] = [
        "CFBundleIdentifier": "com.example.portable",
        "CFBundleName": "Portable",
        "CFBundleExecutable": "Portable"
    ]
    try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: macOS.appendingPathComponent("Portable"))
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: macOS.appendingPathComponent("Portable").path)

    let source = ApplicationSource(id: "removable", rootURL: volumeDir, recursive: false, priority: 0)
    let scanner = ApplicationScanner(sources: [source])
    let first = await scanner.performFullScan()
    #expect(first.records.count == 1, "the fixture app should be found while the source is readable")

    // The volume goes away.
    try FileManager.default.removeItem(at: volumeDir)

    let second = await scanner.performFullScan()
    #expect(
        second.records.count == 1,
        "an unreadable source dropped its records, which would prune them from the user's layout"
    )
    #expect(second.records.first?.bundleIdentifier == "com.example.portable")
}
