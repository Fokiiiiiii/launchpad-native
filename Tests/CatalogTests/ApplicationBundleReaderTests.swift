import Foundation
import Testing
@testable import Catalog

/// Builds a minimal fake `.app` bundle on disk (Info.plist + executable bit)
/// so scanning logic can be tested without touching real system apps.
private func makeFixtureApp(
    named name: String,
    bundleIdentifier: String,
    in directory: URL,
    uiElement: Bool = false,
    backgroundOnly: Bool = false,
    multipleInstancesProhibited: Bool = false
) throws -> URL {
    let bundleURL = directory.appendingPathComponent("\(name).app")
    let contentsURL = bundleURL.appendingPathComponent("Contents")
    let macOSURL = contentsURL.appendingPathComponent("MacOS")
    try FileManager.default.createDirectory(at: macOSURL, withIntermediateDirectories: true)

    var info: [String: Any] = [
        "CFBundleIdentifier": bundleIdentifier,
        "CFBundleDisplayName": name,
        "CFBundleName": name,
        "CFBundleShortVersionString": "1.0",
        "CFBundleExecutable": name,
        "CFBundlePackageType": "APPL"
    ]
    if uiElement { info["LSUIElement"] = true }
    if backgroundOnly { info["LSBackgroundOnly"] = true }
    if multipleInstancesProhibited { info["LSMultipleInstancesProhibited"] = true }

    let plistData = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
    try plistData.write(to: contentsURL.appendingPathComponent("Info.plist"))

    let executableURL = macOSURL.appendingPathComponent(name)
    try Data("#!/bin/sh\nexit 0\n".utf8).write(to: executableURL)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executableURL.path)

    return bundleURL
}

@Test func scanFindsFixtureAppWithExpectedFields() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    _ = try makeFixtureApp(named: "FixtureApp", bundleIdentifier: "com.example.fixture", in: tempDir)

    let source = ApplicationSource(id: "fixture", rootURL: tempDir, recursive: false, priority: 0)
    let records = ApplicationBundleReader.scan(source: source)

    #expect(records.count == 1)
    let record = try #require(records.first)
    #expect(record.bundleIdentifier == "com.example.fixture")
    #expect(record.displayName == "FixtureApp")
    #expect(record.sourceID == "fixture")
    #expect(record.canLaunch == true)
    #expect(record.isBackgroundOnly == false)
    #expect(record.canOpenNewInstance == true)
}

@Test func backgroundOnlyAndMultipleInstanceFlagsAreRead() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    _ = try makeFixtureApp(
        named: "AgentApp",
        bundleIdentifier: "com.example.agent",
        in: tempDir,
        uiElement: true,
        multipleInstancesProhibited: true
    )

    let source = ApplicationSource(id: "fixture", rootURL: tempDir, recursive: false, priority: 0)
    let record = try #require(ApplicationBundleReader.scan(source: source).first)

    #expect(record.isBackgroundOnly == false)
    #expect(record.isMenuBarApp == true)
    #expect(record.canOpenNewInstance == false)
}

@Test func backgroundOnlyAndMenuBarFlagsRemainIndependent() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    _ = try makeFixtureApp(
        named: "BackgroundAgent",
        bundleIdentifier: "com.example.background-agent",
        in: tempDir,
        backgroundOnly: true
    )

    let record = try #require(
        ApplicationBundleReader.scan(
            source: ApplicationSource(id: "fixture", rootURL: tempDir, recursive: false, priority: 0)
        ).first
    )
    #expect(record.isBackgroundOnly == true)
    #expect(record.isMenuBarApp == false)
}

@Test func stableIDDiffersForSameBundleIdentifierAtDifferentPaths() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let subdirA = tempDir.appendingPathComponent("A")
    let subdirB = tempDir.appendingPathComponent("B")
    try FileManager.default.createDirectory(at: subdirA, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: subdirB, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    _ = try makeFixtureApp(named: "DupApp", bundleIdentifier: "com.example.dup", in: subdirA)
    _ = try makeFixtureApp(named: "DupApp", bundleIdentifier: "com.example.dup", in: subdirB)

    let recordA = try #require(ApplicationBundleReader.record(for: subdirA.appendingPathComponent("DupApp.app"), sourceID: "a"))
    let recordB = try #require(ApplicationBundleReader.record(for: subdirB.appendingPathComponent("DupApp.app"), sourceID: "b"))

    #expect(recordA.bundleIdentifier == recordB.bundleIdentifier)
    #expect(recordA.id != recordB.id)
}

@Test func stableIDIsDeterministicAcrossRepeatedReads() throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let bundleURL = try makeFixtureApp(named: "StableApp", bundleIdentifier: "com.example.stable", in: tempDir)

    let first = try #require(ApplicationBundleReader.record(for: bundleURL, sourceID: "s"))
    let second = try #require(ApplicationBundleReader.record(for: bundleURL, sourceID: "s"))

    #expect(first.id == second.id)
}
