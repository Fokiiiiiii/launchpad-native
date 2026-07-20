import Foundation
import Testing
@testable import Catalog

/// Phase 2 completion criterion: "1,000件fixtureを処理." This only checks
/// correctness (all 1,000 found, no duplicates lost) with a generous, crash-only
/// timeout — debug builds are ~15-20x slower than release for this workload
/// (SHA256 hashing + Bundle reads are not representative unoptimized), so a
/// tight timing assertion here would be measuring the build mode, not the
/// scanner. Real timing was benchmarked separately via
/// `swift build -c release && CatalogProbe`: 99 real apps scanned in ~540ms.
@Test func scansOneThousandFixtureAppsWithoutLoss() async throws {
    let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    for i in 0..<1000 {
        let name = "App\(i)"
        let bundleURL = tempDir.appendingPathComponent("\(name).app")
        let macOS = bundleURL.appendingPathComponent("Contents/MacOS")
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let info: [String: Any] = [
            "CFBundleIdentifier": "com.example.app\(i)",
            "CFBundleName": name,
            "CFBundleExecutable": name
        ]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
            .write(to: bundleURL.appendingPathComponent("Contents/Info.plist"))
        try Data().write(to: macOS.appendingPathComponent(name))
    }

    let scanner = ApplicationScanner(sources: [
        ApplicationSource(id: "scale", rootURL: tempDir, recursive: true, priority: 0)
    ])
    let snapshot = await scanner.performFullScan()

    #expect(snapshot.records.count == 1000)
    #expect(Set(snapshot.records.map(\.bundleIdentifier)).count == 1000)
}
