import AppKit
import Catalog
import Grid
import Persistence
import Testing
@testable import Launcher

@Test @MainActor
func launcherViewLoadsEmptySearchStateWithoutInvalidCrossHierarchyConstraints() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("launchpad-launcher-view-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = GridModel(layoutStore: LayoutStore(directory: directory))
    let viewController = LauncherViewController(
        viewModel: LauncherViewModel(),
        gridModel: model,
        iconCache: IconCache(cacheDirectory: directory.appendingPathComponent("icons", isDirectory: true)),
        onDidLaunch: {},
        onDidCancel: {},
        onOpenSettings: {}
    )

    // Regression guard: AppKit used to throw NSGenericException here while
    // activating constraints from the collection view's backgroundView.
    viewController.loadViewIfNeeded()
    #expect(viewController.view.window == nil)
}

@Test @MainActor func launcherWindowAcceptsMouseMovedEvents() {
    let window = LauncherWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100))

    #expect(window.acceptsMouseMovedEvents)
}

@Test @MainActor func launcherWindowStaysOnTheCurrentDesktop() {
    let window = LauncherWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100))

    #expect(window.canBecomeKey)
    #expect(window.canBecomeMain)
    #expect(window.styleMask.contains(.borderless))
    #expect(!window.styleMask.contains(.titled))
    #expect(!window.styleMask.contains(.resizable))
    #expect(!window.styleMask.contains(.nonactivatingPanel))
    #expect(window.collectionBehavior.contains(.canJoinAllSpaces))
    #expect(window.collectionBehavior.contains(.fullScreenAuxiliary))
    #expect(!window.collectionBehavior.contains(.fullScreenPrimary))
    // Must stay false: `show()` toggles the activation policy on every open,
    // and AppKit's blanket hide-on-deactivate ordered the overlay out mid-open.
    // Dismissal on another app activating is the controller's observer's job.
    #expect(!window.hidesOnDeactivate)
}

@Test @MainActor func launcherDoesNotConstrainTheOverlayBelowTheHiddenMenuBar() {
    guard let screen = NSScreen.main else { return }
    let desiredFrame = screen.frame
    let window = LauncherWindow(contentRect: desiredFrame)

    #expect(window.constrainFrameRect(desiredFrame, to: screen) == desiredFrame)
}

@Test @MainActor func launcherBackgroundCoversTheDisplayBehindTheDock() {
    let screen = NSRect(x: 0, y: 0, width: 1_600, height: 1_000)
    let window = LauncherWindow(contentRect: screen)

    window.applyDockVisibilityPreference(
        hideDock: false,
        screenFrame: screen
    )

    #expect(window.frame == screen)
}

@Test @MainActor func launcherCoversTheDisplayWhenDockIsExplicitlyHidden() {
    let screen = NSRect(x: 12, y: 20, width: 1_600, height: 1_000)
    let window = LauncherWindow(contentRect: screen)

    window.applyDockVisibilityPreference(hideDock: true, screenFrame: screen)

    #expect(window.frame == screen)
}

@Test @MainActor func launcherStaysBelowDockWhenDockIsNotHidden() {
    let window = LauncherWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100))
    let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

    window.applyDockVisibilityPreference(hideDock: false)

    #expect(window.level.rawValue < dockLevel)
    // Below the Dock, but still above ordinary application windows (`.normal`)
    // — a full-display overlay sharing `.normal` has no guaranteed ordering
    // against other apps' windows.
    #expect(window.level.rawValue > NSWindow.Level.normal.rawValue)
}

@Test @MainActor func launcherStaysAboveDockOnlyWhenDockIsExplicitlyHidden() {
    let window = LauncherWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100))
    let dockLevel = Int(CGWindowLevelForKey(.dockWindow))

    window.applyDockVisibilityPreference(hideDock: true)

    #expect(window.level.rawValue > dockLevel)
}

@Test @MainActor func privateMenuBarControlKeepsDockIndependent() {
    #expect(LauncherWindowController.launcherPresentationOptions(
        hideDock: false,
        menuBarHiddenPrivately: true
    ) == [])
    #expect(LauncherWindowController.launcherPresentationOptions(
        hideDock: true,
        menuBarHiddenPrivately: true
    ) == [.hideDock])
}

@Test @MainActor func unavailablePrivateControlUsesValidPublicFallbacks() {
    #expect(LauncherWindowController.launcherPresentationOptions(
        hideDock: false,
        menuBarHiddenPrivately: false
    ) == [.autoHideMenuBar, .autoHideDock])
    #expect(LauncherWindowController.launcherPresentationOptions(
        hideDock: true,
        menuBarHiddenPrivately: false
    ) == [.autoHideMenuBar, .hideDock])
}

@Test @MainActor func menuBarVisibilitySymbolsResolveOnMacOS26() {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return }
    #expect(SystemMenuBarVisibility().isAvailable)
}
