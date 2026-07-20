import Catalog
import Foundation
import Persistence
import Testing
@testable import Grid

private func record(_ name: String, id: String) -> ApplicationRecord {
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
        isBackgroundOnly: false,
        iconCacheKey: id,
        canLaunch: true,
        canOpenNewInstance: true,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

@MainActor
private func makeModel(directory: URL) -> GridModel {
    GridModel(layoutStore: LayoutStore(directory: directory))
}

@Test @MainActor func reconcileAppendsNewAppsAlphabetically() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    model.reconcile(with: [record("Zebra", id: "z"), record("Apple", id: "a")])

    let appIDs = model.pages[0].compactMap { item -> String? in
        if case .app(let id) = item { return id.value }
        return nil
    }
    #expect(appIDs.count == 2)
    #expect(model.record(for: StableAppIdentifier(value: appIDs[0]))?.displayName == "Apple")
    #expect(model.record(for: StableAppIdentifier(value: appIDs[1]))?.displayName == "Zebra")
}

@Test @MainActor func reconcilePrunesUninstalledApps() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    model.reconcile(with: [record("Apple", id: "a"), record("Banana", id: "b")])
    #expect(model.pages[0].count == 2)

    model.reconcile(with: [record("Apple", id: "a")]) // Banana "uninstalled"
    #expect(model.pages[0].count == 1)
}

@Test @MainActor func reconcileStartsNewPageWhenCapacityExceeded() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()

    // default grid is 7x5 = 35 capacity
    let records = (0..<40).map { record("App\($0)", id: "id\($0)") }
    model.reconcile(with: records)

    #expect(model.pages.count == 2)
    #expect(model.pages[0].count == 35)
    #expect(model.pages[1].count == 5)
}

@Test @MainActor func moveItemReordersWithinAndAcrossPages() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])

    model.moveItem(fromPage: 0, fromIndex: 2, toPage: 0, toIndex: 0) // C to front
    let bundleIDs = model.pages[0].compactMap { item -> String? in
        guard case .app(let id) = item else { return nil }
        return model.record(for: id)?.bundleIdentifier
    }
    #expect(bundleIDs == ["c", "a", "b"])
}

@Test @MainActor func draggingOneAppOntoAnotherCreatesFolder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b")])

    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)

    #expect(model.pages[0].count == 1)
    guard case .folder(let folderID) = model.pages[0][0] else {
        Issue.record("expected a folder")
        return
    }
    #expect(model.folders[folderID]?.pages.first?.count == 2)
}

@Test @MainActor func draggingIntoExistingFolderAddsToIt() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b"), record("C", id: "c")])

    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    // Now pages[0] = [folder, C] (folder took A+B's slot, C shifted down)
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 1, destinationPage: 0, destinationIndex: 0)

    #expect(model.pages[0].count == 1)
    guard case .folder(let folderID) = model.pages[0][0] else {
        Issue.record("expected a folder")
        return
    }
    #expect(model.folders[folderID]?.pages.first?.count == 3)
}

@Test @MainActor func removeFromFolderDissolvesEmptyFolder() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b")])
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)

    guard case .folder(let folderID) = model.pages[0][0] else {
        Issue.record("expected a folder")
        return
    }

    model.removeFromFolder(folderID, folderPage: 0, folderIndex: 0, toPage: 0)
    #expect(model.folders[folderID] != nil) // still has 1 item

    model.removeFromFolder(folderID, folderPage: 0, folderIndex: 0, toPage: 0)
    #expect(model.folders[folderID] == nil) // dissolved once empty
}

@Test @MainActor func renameFolderUpdatesName() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = makeModel(directory: dir)
    await model.loadDocument()
    model.reconcile(with: [record("A", id: "a"), record("B", id: "b")])
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)

    guard case .folder(let folderID) = model.pages[0][0] else {
        Issue.record("expected a folder")
        return
    }
    model.renameFolder(folderID, to: "Utilities")
    #expect(model.folders[folderID]?.name == "Utilities")
}

@Test @MainActor func saveThenReloadPreservesArrangement() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }

    let model1 = makeModel(directory: dir)
    await model1.loadDocument()
    model1.reconcile(with: [record("A", id: "a"), record("B", id: "b")])
    model1.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    model1.renameFolder({ if case .folder(let id) = model1.pages[0][0] { return id } else { fatalError() } }(), to: "MyFolder")
    await model1.save()

    let model2 = makeModel(directory: dir)
    await model2.loadDocument()
    #expect(model2.folders.values.first?.name == "MyFolder")
    #expect(model2.pages[0].count == 1)
}
