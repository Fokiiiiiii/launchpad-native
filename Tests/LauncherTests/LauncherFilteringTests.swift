import Catalog
import Foundation
import Testing
@testable import Launcher

private func record(
    _ name: String,
    id: String,
    backgroundOnly: Bool = false,
    menuBarApp: Bool = false,
    fileName: String? = nil
) -> ApplicationRecord {
    let bundleURL = URL(fileURLWithPath: "/tmp/\(fileName ?? name).app")
    return ApplicationRecord(
        id: StableAppID(bundleURL: bundleURL, bundleIdentifier: id, teamIdentifier: nil),
        bundleIdentifier: id,
        bundleURL: bundleURL,
        executableURL: nil,
        displayName: name,
        originalDisplayName: name,
        bundleVersion: nil,
        teamIdentifier: nil,
        category: nil,
        sourceID: "test",
        isSystemProtected: false,
        isBackgroundOnly: backgroundOnly,
        isMenuBarApp: menuBarApp,
        iconCacheKey: id,
        canLaunch: true,
        canOpenNewInstance: true,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

@Test func emptyQueryPreservesGridOrder() {
    let records = [record("Zebra", id: "z"), record("Apple", id: "a"), record("Mango", id: "m")]
    let result = LauncherFiltering.filter(records, query: "")
    #expect(result.map(\.displayName) == ["Zebra", "Apple", "Mango"])
}

@Test func filtersByDisplayNameSubstring() {
    let records = [record("Terminal", id: "t"), record("TextEdit", id: "te"), record("Safari", id: "s")]
    let result = LauncherFiltering.filter(records, query: "te")
    #expect(Set(result.map(\.displayName)) == ["Terminal", "TextEdit"])
}

@Test func prefixMatchesRankBeforeSubstringMatches() {
    let records = [record("Notes", id: "n"), record("iNote Pro", id: "inp")]
    let result = LauncherFiltering.filter(records, query: "not")
    #expect(result.first?.displayName == "Notes")
}

@Test func matchingAppsKeepInputOrderWithinTheSameRank() {
    let records = [record("Alpine", id: "alpine"), record("Alpha", id: "alpha")]
    let result = LauncherFiltering.filter(records, query: "al")
    #expect(result.map(\.displayName) == ["Alpine", "Alpha"])
}

@Test func backgroundOnlyAppsAreExcludedFromResults() {
    let records = [record("Visible", id: "v"), record("HelperAgent", id: "h", backgroundOnly: true)]
    let result = LauncherFiltering.filter(records, query: "")
    #expect(result.map(\.displayName) == ["Visible"])
}

@Test func menuBarAppsAreShownByDefaultAndCanBeExcluded() {
    let records = [
        record("Visible", id: "v"),
        record("CodexBar", id: "cb", menuBarApp: true),
        record("Agent", id: "agent", backgroundOnly: true, menuBarApp: true)
    ]

    #expect(LauncherFiltering.filter(records, query: "").map(\.displayName) == ["Visible", "CodexBar"])
    #expect(LauncherFiltering.filter(records, query: "", showMenuBarApplications: false).map(\.displayName) == ["Visible"])
    // Background-only wins over the opt-in menu-bar policy.
    #expect(LauncherFiltering.filter(records, query: "", showMenuBarApplications: true).contains { $0.displayName == "Agent" } == false)
}

@Test func queryIsCaseInsensitive() {
    let records = [record("Xcode", id: "x")]
    let result = LauncherFiltering.filter(records, query: "XCO")
    #expect(result.count == 1)
}

@Test func searchesBundleIdentifierAndApplicationFileNameAfterDisplayNameMatches() {
    let records = [
        record("Safari", id: "com.apple.Safari"),
        record("Utilities", id: "org.example.tool", fileName: "Browser")
    ]

    #expect(LauncherFiltering.filter(records, query: "apple.safari").map(\.displayName) == ["Safari"])
    #expect(LauncherFiltering.filter(records, query: "browser").map(\.displayName) == ["Utilities"])
}

/// Phase 9 performance target: filtering must stay well under one frame
/// (16ms at 60Hz) on MainActor even at catalog sizes around 1,000 apps —
/// the real search field calls this synchronously while the user types.
@Test @MainActor func filteringOneThousandRecordsStaysUnderOneFrame() {
    let records = (0..<1000).map { record("App \($0)", id: "app\($0)") }
    let start = DispatchTime.now()
    let result = LauncherFiltering.filter(records, query: "App 5")
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    #expect(!result.isEmpty)
    #expect(ms < 16, "filtering 1,000 records took \(ms)ms, expected < 16ms")
}
