import AppKit
import Catalog
import Foundation
import Persistence
import Testing
@testable import Grid

/// Drives the real presenter against a real (offscreen) window, rather than
/// calling layout helpers in isolation.
///
/// The helpers were already well covered when the folder shipped with no icons
/// in it at all: a refactor dropped the line holding the panel controller, so
/// every async icon load resolved against a deallocated `self` and was thrown
/// away. Nothing in 273 passing tests noticed, because nothing exercised the
/// path from "open a folder" to "its tiles have icons".
private func presentationRecord(_ name: String) -> ApplicationRecord {
    ApplicationRecord(
        id: StableAppID(bundleURL: URL(fileURLWithPath: "/tmp/\(name).app"), bundleIdentifier: name, teamIdentifier: nil),
        bundleIdentifier: name,
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
        isMenuBarApp: false,
        iconCacheKey: name,
        canLaunch: true,
        canOpenNewInstance: true,
        lastSeenModificationDate: Date(timeIntervalSince1970: 0)
    )
}

@MainActor
private func modelWithFolder(itemCount count: Int, directory: URL) async -> (GridModel, FolderID) {
    let model = GridModel(layoutStore: LayoutStore(directory: directory))
    await model.loadDocument()
    model.reconcile(with: (1...count).map { presentationRecord("app\($0)") })
    model.createOrJoinFolder(sourcePage: 0, sourceIndex: 0, destinationPage: 0, destinationIndex: 1)
    while model.pages[0].count > 1 {
        model.createOrJoinFolder(sourcePage: 0, sourceIndex: 1, destinationPage: 0, destinationIndex: 0)
    }
    guard case .folder(let id) = model.pages[0][0] else {
        Issue.record("expected a folder")
        return (model, FolderID())
    }
    return (model, id)
}

/// An offscreen window, because several things here only behave correctly in a
/// real window: `cacheDisplay` produces blank pixels for a view that has never
/// belonged to one, and a view outside any window never lays out.
///
/// `isReleasedWhenClosed` is turned off deliberately. A programmatically
/// created `NSWindow` defaults to freeing itself on `close()`, and with several
/// tests each closing their own window the run segfaulted — passing
/// individually, failing together, which is the least useful failure mode a
/// test suite can have. The window is ordered out instead and left to ARC.
@MainActor
private func makeHost(size: NSSize) -> (NSWindow, NSView) {
    let window = NSWindow(
        contentRect: NSRect(origin: NSPoint(x: -30_000, y: -30_000), size: size),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    let host = NSView(frame: NSRect(origin: .zero, size: size))
    host.wantsLayer = true
    window.contentView = host
    window.orderBack(nil)
    return (window, host)
}

@MainActor
private func openFolder(
    itemCount: Int,
    directory: URL,
    hostSize: NSSize = NSSize(width: 1_680, height: 1_050)
) async -> (FolderOverlayPresenter, NSWindow, NSView) {
    let (model, folderID) = await modelWithFolder(itemCount: itemCount, directory: directory)
    let (window, host) = makeHost(size: hostSize)
    let presenter = FolderOverlayPresenter(model: model, iconCache: IconCache())
    presenter.open(
        folderID,
        in: host,
        metrics: FolderOverlayPresenter.Metrics(iconSize: 96, configuredColumns: 6),
        onLaunch: { _ in },
        onItemDraggedOut: { _, _ in },
        onDidClose: {}
    )
    return (presenter, window, host)
}

/// The regression that 273 tests missed: the panel is held by the presenter and
/// nothing else. Losing that hold renders the folder as empty placeholders.
@Test @MainActor func anOpenedFolderKeepsItsPanelAliveAndFillsInIcons() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (presenter, window, _) = await openFolder(itemCount: 6, directory: dir)
    defer { window.orderOut(nil) }

    let panel = try #require(presenter.presentedPanelForTesting, "the presenter must hold the panel")
    #expect(panel.visibleTileCountForTesting == 6)

    // Icons arrive asynchronously; poll rather than sleeping a fixed time.
    for _ in 0..<40 where panel.resolvedIconCountForTesting < 6 {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(panel.resolvedIconCountForTesting == 6, "every tile should have received an icon")
    // And the panel is still the one the presenter holds — not a replacement.
    #expect(presenter.presentedPanelForTesting === panel)
}

/// Closing has to actually take the panel down, and say so, or whatever the
/// caller hid while it was open stays hidden.
@Test @MainActor func closingAFolderTearsItDownAndReportsIt() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (model, folderID) = await modelWithFolder(itemCount: 4, directory: dir)
    let (window, host) = makeHost(size: NSSize(width: 1_680, height: 1_050))
    defer { window.orderOut(nil) }

    let presenter = FolderOverlayPresenter(model: model, iconCache: IconCache())
    var didClose = false
    presenter.open(
        folderID,
        in: host,
        metrics: FolderOverlayPresenter.Metrics(iconSize: 96, configuredColumns: 6),
        onLaunch: { _ in },
        onItemDraggedOut: { _, _ in },
        onDidClose: { didClose = true }
    )
    #expect(host.subviews.count == 1)

    presenter.close()
    for _ in 0..<40 where !didClose {
        try await Task.sleep(for: .milliseconds(50))
    }
    #expect(didClose, "the caller must be told, so it can restore what it hid")
    #expect(host.subviews.isEmpty, "the backdrop must be removed from the host")
    #expect(presenter.presentedPanelForTesting == nil)
}

/// The panel has to be inside the host it was given — an off-screen or
/// zero-sized panel is invisible however correct its contents are.
@Test @MainActor func theOpenedPanelLandsInsideItsHost() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let hostSize = NSSize(width: 1_680, height: 1_050)
    let (presenter, window, host) = await openFolder(itemCount: 9, directory: dir, hostSize: hostSize)
    defer { window.orderOut(nil) }

    let panel = try #require(presenter.presentedPanelForTesting)
    let frame = panel.view.frame
    #expect(frame.width > 200 && frame.height > 100, "panel collapsed to \(frame.size)")
    #expect(frame.minX >= 0 && frame.minY >= 0)
    #expect(frame.maxX <= hostSize.width && frame.maxY <= hostSize.height)
    #expect(host.subviews.count == 1, "exactly one backdrop should be added")
}

// MARK: - What actually reaches the screen

/// The last layer: not "the panel exists" or "the tiles hold icons", but that
/// something recognisable is genuinely drawn where the folder's contents belong.
///
/// Both of this project's icon failures would have passed the checks above and
/// failed here — the transparent snapshot (a bitmap that reported success while
/// holding nothing) and the empty-placeholder folder.
///
/// Measured in bands rather than against the panel as a whole, for two reasons.
/// The glass background does not appear in a `cacheDisplay` bitmap at all — it
/// is a live compositing effect, so coverage of the full panel is low even when
/// it looks right on screen. And coverage alone cannot tell a row of real icons
/// from a row of blank placeholders: both fill their boxes. Variation can.
@Test @MainActor func anOpenedFolderActuallyDrawsItsContents() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let (presenter, window, host) = await openFolder(itemCount: 6, directory: dir)
    defer { window.orderOut(nil) }

    let panel = try #require(presenter.presentedPanelForTesting)
    for _ in 0..<40 where panel.resolvedIconCountForTesting < 6 {
        try await Task.sleep(for: .milliseconds(50))
    }
    host.layoutSubtreeIfNeeded()

    let bitmap = try #require(RenderProbe.render(panel.view), "panel produced no bitmap at all")
    let bounds = panel.view.bounds
    let bandCount = 5
    let bands = (0..<bandCount).map { index in
        NSRect(
            x: bounds.minX,
            y: bounds.minY + bounds.height * Double(index) / Double(bandCount),
            width: bounds.width,
            height: bounds.height / Double(bandCount)
        )
    }
    let coverage = bands.map { RenderProbe.coverage(bitmap, in: $0) }
    let variation = bands.map { RenderProbe.colorVariation(bitmap, in: $0) }

    // Something drew: a fully transparent bitmap is the exact shape of a bug
    // this project has shipped before.
    #expect((coverage.max() ?? 0) > 0.2, "nothing drew anywhere — coverage by band: \(coverage)")
    // And what drew is picture-like, not a flat wash of placeholders.
    #expect((variation.max() ?? 0) > 0.15, "the panel drew, but uniformly — variation by band: \(variation)")
}
