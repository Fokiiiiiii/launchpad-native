import Catalog
import Foundation
import Testing
@testable import Launcher

private func record(_ name: String, id: String, backgroundOnly: Bool = false) -> ApplicationRecord {
    ApplicationRecord(
        id: StableAppID(bundleURL: URL(fileURLWithPath: "/tmp/\(name).app"), bundleIdentifier: id, teamIdentifier: nil),
        bundleIdentifier: id,
        bundleURL: URL(fileURLWithPath: "/tmp/\(name).app"),
        executableURL: nil,
        displayName: name,
        originalDisplayName: name,
        bundleVersion: nil,
        teamIdentifier: nil,
        category: nil,
        sourceID: "test",
        isSystemProtected: false,
        isBackgroundOnly: backgroundOnly,
        iconCacheKey: id,
        canLaunch: true,
        canOpenNewInstance: true,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

@Test func emptyQueryReturnsAllSortedAlphabetically() {
    let records = [record("Zebra", id: "z"), record("Apple", id: "a"), record("Mango", id: "m")]
    let result = LauncherFiltering.filter(records, query: "")
    #expect(result.map(\.displayName) == ["Apple", "Mango", "Zebra"])
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

@Test func backgroundOnlyAppsAreExcludedFromResults() {
    let records = [record("Visible", id: "v"), record("HelperAgent", id: "h", backgroundOnly: true)]
    let result = LauncherFiltering.filter(records, query: "")
    #expect(result.map(\.displayName) == ["Visible"])
}

@Test func queryIsCaseInsensitive() {
    let records = [record("Xcode", id: "x")]
    let result = LauncherFiltering.filter(records, query: "XCO")
    #expect(result.count == 1)
}
