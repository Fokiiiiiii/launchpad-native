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
