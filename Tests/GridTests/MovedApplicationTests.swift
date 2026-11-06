import Catalog
import Foundation
import Persistence
import Testing
@testable import Grid

private func record(_ name: String, id: String, team: String? = nil) -> ApplicationRecord {
    let url = URL(fileURLWithPath: "/tmp/\(name).app")
    return ApplicationRecord(
        id: StableAppID(bundleURL: url, bundleIdentifier: id, teamIdentifier: team),
        bundleIdentifier: id,
        bundleURL: url,
        executableURL: nil,
        displayName: name,
        originalDisplayName: name,
        bundleVersion: nil,
        teamIdentifier: team,
        category: nil,
        sourceID: "test",
        isSystemProtected: false,
        isBackgroundOnly: false,
        iconCacheKey: id,
        canLaunch: true,
        canOpenNewInstance: true,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

/// The same app, somewhere else — a move or a rename.
private func moved(_ original: ApplicationRecord, to path: String) -> ApplicationRecord {
    let url = URL(fileURLWithPath: path)
    return ApplicationRecord(
        id: StableAppID(bundleURL: url, bundleIdentifier: original.bundleIdentifier, teamIdentifier: original.teamIdentifier),
        bundleIdentifier: original.bundleIdentifier,
        bundleURL: url,
        executableURL: nil,
        displayName: original.displayName,
        originalDisplayName: original.originalDisplayName,
        bundleVersion: nil,
        teamIdentifier: original.teamIdentifier,
        category: nil,
        sourceID: "test",
        isSystemProtected: false,
        isBackgroundOnly: false,
        iconCacheKey: original.iconCacheKey,
        canLaunch: true,
        canOpenNewInstance: true,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

@MainActor
private func makeModel(_ directory: URL) -> GridModel {
    GridModel(layoutStore: LayoutStore(directory: directory))
}

@MainActor
private func placedAppIDs(_ model: GridModel) -> [String] {
    model.pages.flatMap { $0 }.compactMap { item in
        guard case .app(let id) = item else { return nil }
        return id.value
    }
}

private func temporaryDirectory() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
}

/// An app's identifier is derived from its path, so moving or renaming it made
/// the layout lose its place, its alias and whether it was hidden: all of that
/// was saved under an identifier that no longer matched anything.
@Test @MainActor func aMovedAppKeepsItsPlaceAndItsAlias() async throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(dir)
    await model.loadDocument()
    let a = record("A", id: "com.example.a")
    let b = record("B", id: "com.example.b")
    let c = record("C", id: "com.example.c")
    model.reconcile(with: [a, b, c])
    model.setAlias("Mine", for: b.id)
    let movedB = moved(b, to: "/Applications/Renamed B.app")

    model.reconcile(with: [a, movedB, c])

    #expect(placedAppIDs(model) == [a.id.value, movedB.id.value, c.id.value])
    #expect(model.alias(for: movedB.id) == "Mine")
    #expect(model.alias(for: b.id) == nil)
}

/// A legacy import is applied only to a layout with nothing in it, and a first
/// run with an empty layout holds off filling the grid from a partial startup
/// cache so that import still has somewhere to land.
@Test @MainActor func aLayoutHasNoArrangementUntilSomethingIsPlacedInIt() async throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(dir)
    await model.loadDocument()
    #expect(model.hasNoArrangement)

    model.reconcile(with: [record("A", id: "com.example.a")])
    #expect(!model.hasNoArrangement)
}

/// Search lists apps in the grid's order and listens to a different signal than
/// the grid does; a move that only told the grid left equal-rank results in the
/// order from before it.
@Test @MainActor func reorderingTellsSearchAsWellAsTheGrid() async throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "com.example.a"), record("B", id: "com.example.b"), record("C", id: "com.example.c")])
    var searchSignals = 0
    model.onSearchableRecordsChange = { searchSignals += 1 }

    model.moveItem(fromPage: 0, fromIndex: 0, toPage: 0, toIndex: 2)
    #expect(searchSignals == 1)

    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    #expect(searchSignals == 2)

    model.applySortMode(.name)
    #expect(searchSignals == 3)
}

@Test @MainActor func aMovedAppInsideAFolderStaysInThatFolder() async throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(dir)
    await model.loadDocument()
    let a = record("A", id: "com.example.a")
    let b = record("B", id: "com.example.b")
    let imported = Folder(name: "Tools", pages: [[.app(a.id.asPersistenceIdentifier), .app(b.id.asPersistenceIdentifier)]])
    #expect(model.applyLegacyImportIfFirstRun(LegacyImportResult(
        folders: [imported], unplacedAppOrder: [.folder(imported.id)], unresolvedBundleIDs: []
    )))
    model.reconcile(with: [a, b])
    let movedA = moved(a, to: "/Applications/Utilities/A.app")

    model.reconcile(with: [movedA, b])

    let folderApps = try #require(model.folders[imported.id]).pages.flatMap { $0 }.compactMap { item -> String? in
        guard case .app(let id) = item else { return nil }
        return id.value
    }
    #expect(folderApps == [movedA.id.value, b.id.value])
    #expect(!placedAppIDs(model).contains(movedA.id.value), "it was not also appended to a page")
}

/// A move seen only after a relaunch: nothing of the old record is in memory, so
/// what the layout saved about the app is all there is to go on.
@Test @MainActor func aMoveMadeWhileTheLauncherWasNotRunningIsRecognisedToo() async throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(dir)
    await model.loadDocument()
    let a = record("A", id: "com.example.a")
    let b = record("B", id: "com.example.b")
    model.reconcile(with: [a, b])
    model.setAlias("Mine", for: b.id)
    await model.save()

    let reopened = makeModel(dir)
    await reopened.loadDocument()
    let movedB = moved(b, to: "/Applications/Renamed B.app")
    reopened.reconcile(with: [a, movedB])

    #expect(placedAppIDs(reopened) == [a.id.value, movedB.id.value])
    #expect(reopened.alias(for: movedB.id) == "Mine")
}

/// Two copies that went two ways cannot be told apart, so neither is guessed at.
@Test @MainActor func twoCandidatesAreNotGuessedBetween() async throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(dir)
    await model.loadDocument()
    let first = record("B", id: "com.example.b")
    let second = moved(first, to: "/tmp/B2.app")
    model.reconcile(with: [first, second])
    model.setAlias("Mine", for: first.id)

    let newFirst = moved(first, to: "/x/B.app")
    let newSecond = moved(first, to: "/y/B.app")
    model.reconcile(with: [newFirst, newSecond])

    #expect(model.alias(for: newFirst.id) == nil)
    #expect(model.alias(for: newSecond.id) == nil)
}

@Test @MainActor func aDifferentSigningTeamIsNotTheSameApp() async throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(dir)
    await model.loadDocument()
    let original = record("B", id: "com.example.b", team: "TEAM1")
    model.reconcile(with: [original])
    model.setAlias("Mine", for: original.id)

    let lookalike = record("B2", id: "com.example.b", team: "TEAM2")
    model.reconcile(with: [lookalike])

    #expect(model.alias(for: lookalike.id) == nil)
}

/// The startup snapshot lags the disk, so it is not evidence that anything moved.
@Test @MainActor func aSnapshotThatIsNotAuthoritativeMovesNothing() async throws {
    let dir = temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(dir)
    await model.loadDocument()
    let b = record("B", id: "com.example.b")
    model.reconcile(with: [b])
    model.setAlias("Mine", for: b.id)
    let movedB = moved(b, to: "/Applications/Renamed B.app")

    model.reconcile(with: [movedB], prunesMissingItems: false)

    #expect(model.alias(for: b.id) == "Mine")
    #expect(model.alias(for: movedB.id) == nil)
}
