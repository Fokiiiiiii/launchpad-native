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

@Test func fuzzyMatchesKeepCharacterOrderAndStayBelowDirectMatches() {
    let records = [
        record("Google Chrome", id: "chrome"),
        record("Guitar", id: "guitar"),
        record("Safari", id: "safari")
    ]

    #expect(LauncherFiltering.filter(records, query: "gcr").map(\.displayName) == ["Google Chrome"])
    #expect(LauncherFiltering.filter(records, query: "gua").map(\.displayName) == ["Guitar"])
}

/// Filtering must stay well under one frame (16ms at 60Hz) even at catalog
/// sizes around 1,000 apps — the search field calls this synchronously on
/// MainActor while the user types. Measured the way the launcher runs it,
/// against a prepared index.
@Test @MainActor func filteringOneThousandRecordsStaysUnderOneFrame() {
    let index = (0..<1000).map { SearchableApplication(record: record("App \($0)", id: "app\($0)")) }
    let start = DispatchTime.now()
    let result = LauncherFiltering.filter(index, query: "App 5")
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    #expect(!result.isEmpty)
    #expect(ms < 16, "filtering 1,000 records took \(ms)ms, expected < 16ms")
}

/// Building the index is the price of not paying per keystroke, and it runs
/// on MainActor whenever the catalog changes. It has to stay small enough not
/// to be felt at launch or after an app is installed.
@Test @MainActor func buildingTheIndexForOneThousandRecordsStaysCheap() {
    let records = (0..<1000).map { record("App \($0)", id: "app\($0)") }
    let start = DispatchTime.now()
    let index = records.map(SearchableApplication.init(record:))
    let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    #expect(index.count == 1000)
    #expect(ms < 120, "building an index of 1,000 records took \(ms)ms")
}

// MARK: - Ranking tiers

@Test func aWordInsideTheNameRanksAboveALooseSubstring() {
    let records = [
        record("Barcode Reader", id: "barcode"),
        record("Visual Studio Code", id: "vscode")
    ]
    // "code" starts a word in one name and sits mid-word in the other.
    #expect(LauncherFiltering.filter(records, query: "code").map(\.displayName)
        == ["Visual Studio Code", "Barcode Reader"])
}

/// "gc" abbreviates one of these and merely threads through the other, so the
/// abbreviation has to win despite coming second in the caller's order.
@Test func initialsFindAnAppByHowItIsAbbreviated() {
    // Identifiers deliberately free of "gc" so only the names decide.
    let records = [
        record("Graphic Editor", id: "com.example.editor"),
        record("Google Chrome", id: "com.example.browser"),
        record("Safari", id: "com.example.safari")
    ]
    let result = LauncherFiltering.filter(records, query: "gc").map(\.displayName)
    #expect(result.first == "Google Chrome")
    #expect(result.contains("Safari") == false)
}

/// A one-letter query is answered by the name and word-start tiers before the
/// abbreviation tier can see it, so results stay in the caller's order rather
/// than being reshuffled by an accidental abbreviation match.
@Test func aSingleLetterKeepsTheCallersOrder() {
    let records = [record("Slack", id: "slack"), record("Safari", id: "safari")]
    #expect(LauncherFiltering.filter(records, query: "s").map(\.displayName) == ["Slack", "Safari"])
}

@Test func anExactNameWinsOverAnAppThatMerelyStartsWithIt() {
    let records = [record("Notes Pro", id: "pro"), record("Notes", id: "notes")]
    #expect(LauncherFiltering.filter(records, query: "notes").first?.displayName == "Notes")
}

@Test func accentsAndCaseAreIgnoredOnBothSides() {
    let records = [record("Café Player", id: "cafe")]
    #expect(LauncherFiltering.filter(records, query: "cafe").count == 1)
    #expect(LauncherFiltering.filter(records, query: "CAFÉ").count == 1)
}

// MARK: - Japanese names

/// An app whose name is only ever shown in Japanese is otherwise unreachable
/// without switching input modes mid-search.
@Test func aJapaneseNameIsFoundByItsLatinReading() {
    let records = [record("メモ", id: "com.example.memo"), record("Safari", id: "safari")]
    #expect(LauncherFiltering.filter(records, query: "memo").map(\.displayName) == ["メモ"])
}

@Test func kanjiIsReadRatherThanTransliterated() {
    // A general Latin transform renders these as their Chinese readings; the
    // reading here has to be the Japanese one.
    #expect(LatinReading.of("写真").contains("shashin"))
    #expect(LatinReading.of("設定").contains("settei"))
}

@Test func namesWithoutJapaneseSkipTheReadingEntirely() {
    #expect(LatinReading.of("Safari").isEmpty)
    #expect(LatinReading.of("").isEmpty)
}

/// The reading is a fallback, not a competitor: a direct hit on a Latin name
/// must not be pushed below an app that only matched through its reading.
@Test func aDirectNameMatchOutranksAReadingMatch() {
    let records = [record("メモリ計測", id: "jp"), record("Memory Monitor", id: "mem")]
    #expect(LauncherFiltering.filter(records, query: "memo").first?.displayName == "Memory Monitor")
}
