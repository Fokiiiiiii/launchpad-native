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

@Test @MainActor
func searchSurfaceUsesPagingWithoutScrollbars() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("launchpad-search-surface-test-\(UUID().uuidString)", isDirectory: true)
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

    viewController.loadViewIfNeeded()

    func searchScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView,
           scrollView.documentView is SearchResultsCollectionView {
            return scrollView
        }
        for child in view.subviews {
            if let result = searchScrollView(in: child) { return result }
        }
        return nil
    }

    guard let scrollView = searchScrollView(in: viewController.view) else {
        Issue.record("search results scroll view was not installed")
        return
    }
    #expect(!scrollView.hasVerticalScroller)
    #expect(!scrollView.hasHorizontalScroller)
}

@Test @MainActor
func searchEmptyStateOnlyParticipatesInAccessibilityWhenVisible() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("launchpad-search-accessibility-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let model = GridModel(layoutStore: LayoutStore(directory: directory))
    let viewModel = LauncherViewModel()
    let viewController = LauncherViewController(
        viewModel: viewModel,
        gridModel: model,
        iconCache: IconCache(cacheDirectory: directory.appendingPathComponent("icons", isDirectory: true)),
        onDidLaunch: {},
        onDidCancel: {},
        onOpenSettings: {}
    )
    viewController.loadViewIfNeeded()

    func searchCollection(in view: NSView) -> SearchResultsCollectionView? {
        if let collection = view as? SearchResultsCollectionView { return collection }
        return view.subviews.lazy.compactMap(searchCollection).first
    }

    guard let emptyState = searchCollection(in: viewController.view)?.backgroundView else {
        Issue.record("search empty state was not installed")
        return
    }
    viewModel.setRecords([record("Alpha", id: "alpha")])
    viewController.debugSetSearchQuery("Alpha")
    #expect(emptyState.isHidden)
    #expect(!emptyState.isAccessibilityElement())

    viewController.debugSetSearchQuery("missing")
    #expect(!emptyState.isHidden)
    #expect(emptyState.isAccessibilityElement())
    viewController.view.frame = NSRect(x: 0, y: 0, width: 1_200, height: 800)
    viewController.view.layoutSubtreeIfNeeded()
    emptyState.layoutSubtreeIfNeeded()
    guard let content = emptyState.subviews.first else {
        Issue.record("search empty-state content was not installed")
        return
    }
    #expect(abs(content.frame.midY - emptyState.bounds.midY) < 1)
}

@Test @MainActor func launcherWindowAcceptsMouseMovedEvents() {
    let window = LauncherWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100))

    #expect(window.acceptsMouseMovedEvents)
}

@Test @MainActor func launcherWindowRoutesCommonCommandShortcuts() {
    let window = LauncherWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100))
    var openedSettings = false
    var focusedSearch = false
    var closed = false
    window.onOpenSettings = { openedSettings = true }
    window.onFocusSearch = { focusedSearch = true }
    window.onCloseWindow = { closed = true }

    let settingsEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: ",",
        charactersIgnoringModifiers: ",",
        isARepeat: false,
        keyCode: 41
    )
    let searchEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "f",
        charactersIgnoringModifiers: "f",
        isARepeat: false,
        keyCode: 3
    )
    let closeEvent = NSEvent.keyEvent(
        with: .keyDown,
        location: .zero,
        modifierFlags: .command,
        timestamp: 0,
        windowNumber: window.windowNumber,
        context: nil,
        characters: "w",
        charactersIgnoringModifiers: "w",
        isARepeat: false,
        keyCode: 13
    )

    #expect(settingsEvent.map(window.performKeyEquivalent) == true)
    #expect(searchEvent.map(window.performKeyEquivalent) == true)
    #expect(closeEvent.map(window.performKeyEquivalent) == true)
    #expect(openedSettings)
    #expect(focusedSearch)
    #expect(closed)
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
    // AppKit must not order the overlay out independently; dismissal on
    // another app activating is the controller's observer's job.
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
    #expect(window.level == .floating)
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

/// macOS 27 keeps the system's hot corners quiet while the launcher is open,
/// but the option only takes effect alongside a Dock option. The tests above
/// pin the pre-27 sets, which leave the corners alone.
@Test @MainActor func screenCornersAreSuppressedWhereADockOptionAllowsIt() {
    guard #available(macOS 27, *) else { return }
    #expect(LauncherWindowController.launcherPresentationOptions(
        hideDock: false,
        menuBarHiddenPrivately: false,
        suppressesScreenCorners: true
    ) == [.autoHideMenuBar, .autoHideDock, .disableScreenCornerInteractions])
    #expect(LauncherWindowController.launcherPresentationOptions(
        hideDock: true,
        menuBarHiddenPrivately: false,
        suppressesScreenCorners: true
    ) == [.autoHideMenuBar, .hideDock, .disableScreenCornerInteractions])
    #expect(LauncherWindowController.launcherPresentationOptions(
        hideDock: true,
        menuBarHiddenPrivately: true,
        suppressesScreenCorners: true
    ) == [.hideDock, .disableScreenCornerInteractions])
    // The Dock stays fully visible here, so there is nothing to attach to.
    #expect(LauncherWindowController.launcherPresentationOptions(
        hideDock: false,
        menuBarHiddenPrivately: true,
        suppressesScreenCorners: true
    ) == [])
}

@Test @MainActor func menuBarVisibilitySymbolsResolveOnMacOS26() {
    guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion >= 26 else { return }
    #expect(SystemMenuBarVisibility().isAvailable)
}

/// The search pill's controls must still take their own clicks now that the
/// glass contains them on macOS 27. A search field that could not be clicked
/// was a real, user-reported failure here.
@Test @MainActor func searchPillControlsStayClickableOnTheirGlass() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("launchpad-search-pill-test-\(UUID().uuidString)", isDirectory: true)
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
    let window = NSWindow(
        contentRect: NSRect(x: -30_000, y: -30_000, width: 1_280, height: 800),
        styleMask: [.borderless],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    defer { window.close() }
    window.contentView = viewController.view
    viewController.view.frame = NSRect(x: 0, y: 0, width: 1_280, height: 800)
    viewController.view.layoutSubtreeIfNeeded()

    // The clear button only shows while there is a query.
    let controls = viewController.searchPillControlsForTesting.filter { !$0.isHidden }
    #expect(controls.count >= 2)
    for control in controls {
        let center = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: nil)
        let hit = try #require(viewController.view.hitTest(center))
        #expect(hit === control || hit.isDescendant(of: control), "a click on \(type(of: control)) landed on \(hit)")
        // The glass can only respond to the controls it contains.
        if #available(macOS 27, *), !NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency {
            let glass = sequence(first: control.superview, next: { $0?.superview })
                .compactMap { $0 as? NSGlassEffectView }
                .first
            #expect(glass?.effectIsInteractive == true, "on macOS 27 the search pill's glass should contain its controls")
        }
    }
}
