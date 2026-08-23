import AppKit
import Catalog
import CoreGraphics
import Diagnostics
import Grid
import Persistence

/// Owns the single launcher window instance for the whole app — callers
/// never create a second one, which is what satisfies "複数ディスプレイで
/// 同時に複数インスタンスを表示しない": there is exactly one window, moved
/// to whichever screen is relevant each time it opens.
@MainActor
public final class LauncherWindowController: NSObject, NSWindowDelegate {
    private var window: LauncherWindow?
    private var viewController: LauncherViewController?
    private var rootContentView: NSView?
    /// Held so `updateBackgroundSettings(mode:materialIntensity:blursWallpaper:)`
    /// can live-update the retained background when Settings' controls change.
    private var backgroundView: LauncherBackgroundView?
    private let viewModel = LauncherViewModel()
    private let gridModel: GridModel
    private let iconCache: IconCache
    /// Pending delayed release of the decoded-icon memory cache — see
    /// `scheduleIconCacheEviction()`. Cancelled whenever the launcher reopens.
    private var iconEvictionTask: Task<Void, Never>?
    private static let iconEvictionDelayNanoseconds: UInt64 = 60_000_000_000
    private let menuBarVisibility = SystemMenuBarVisibility()
    private var hasAttemptedLegacyImport = false
    private var latestRecords: [ApplicationRecord] = []
    private var onOpenSettings: (() -> Void)?
    private var onRequestUninstall: ((String) -> Void)?
    private var onDidHide: (() -> Void)?
    /// Incremented on every show()/hide() call — a hide() animation's
    /// completion handler checks this before calling `orderOut`, so an
    /// interrupting show() (same-trigger reopen mid-close-animation, or the
    /// pinch/spread gestures firing in quick succession) never has its
    /// window yanked back out from under it by a stale completion. This is
    /// the AppKit-reachable version of apple-design's interruptibility rule
    /// — there's no true velocity-carrying spring re-target across a
    /// reversal here, but a reversal can never leave the window in the
    /// wrong final state either.
    private var animationGeneration = 0
    public var isVisible: Bool {
        window?.isVisible ?? false
    }

    public var currentScreen: NSScreen? {
        window?.screen
    }

    public init(iconCache: IconCache, layoutStore: LayoutStore) {
        self.iconCache = iconCache
        self.gridModel = GridModel(layoutStore: layoutStore)
        super.init()
    }

    deinit {
        let menuBarVisibility = menuBarVisibility
        Task { @MainActor in
            _ = menuBarVisibility.setHidden(false)
            NSApp.presentationOptions = []
        }
    }

    private func setLauncherPresentation(active: Bool) {
        let menuBarStatus = menuBarVisibility.setHidden(active)
        let menuBarHiddenPrivately = menuBarStatus == 0
        NSApp.presentationOptions = active
            ? Self.launcherPresentationOptions(
                hideDock: gridModel.hideDockWhileLauncherOpen,
                menuBarHiddenPrivately: menuBarHiddenPrivately
            )
            : []
        if menuBarStatus == nil {
            DiagnosticsLog.launcher.error(
                "system menu-bar visibility API unavailable; using presentation-options fallback"
            )
        } else if let menuBarStatus, menuBarStatus != 0 {
            DiagnosticsLog.launcher.error(
                "system menu-bar visibility update failed with status \(menuBarStatus, privacy: .public)"
            )
        }
        DiagnosticsLog.launcher.info(
            "launcher presentation: active=\(active, privacy: .public), menuBarStatus=\(String(describing: menuBarStatus), privacy: .public), optionsRaw=\(NSApp.presentationOptions.rawValue, privacy: .public), currentSystemOptionsRaw=\(NSApp.currentSystemPresentationOptions.rawValue, privacy: .public), hideDock=\(self.gridModel.hideDockWhileLauncherOpen, privacy: .public), isActive=\(NSApp.isActive, privacy: .public), frontmostPID=\(Self.frontmostPID, privacy: .public)"
        )
    }

    static func launcherPresentationOptions(
        hideDock: Bool,
        menuBarHiddenPrivately: Bool
    ) -> NSApplication.PresentationOptions {
        if menuBarHiddenPrivately {
            return hideDock ? [.hideDock] : []
        }
        return hideDock ? [.autoHideMenuBar, .hideDock] : [.autoHideMenuBar, .autoHideDock]
    }

    public func prepareForTermination() {
        setLauncherPresentation(active: false)
    }

    private static var frontmostPID: pid_t {
        NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
    }

    private func logOverlayState(_ event: String, window: NSWindow? = nil) {
        let target = window ?? self.window
        DiagnosticsLog.launcher.info(
            "overlay state: event=\(event, privacy: .public), styleMaskFullScreen=\(target?.styleMask.contains(.fullScreen) ?? false, privacy: .public), fullScreenPrimary=\(target?.collectionBehavior.contains(.fullScreenPrimary) ?? false, privacy: .public), optionsRaw=\(NSApp.presentationOptions.rawValue, privacy: .public), currentSystemOptionsRaw=\(NSApp.currentSystemPresentationOptions.rawValue, privacy: .public), isActive=\(NSApp.isActive, privacy: .public), frontmostPID=\(Self.frontmostPID, privacy: .public)"
        )
    }

    private func refreshOverlayLayout(reason: String) {
        if let screen = window?.screen {
            backgroundView?.update(screen: screen, viewportOrigin: .zero)
        }
        viewController?.refreshDockLayout()
        logOverlayState(reason)
    }

    /// Set once by the composition root (`AppDelegate`) after both this
    /// controller and the Settings window controller exist — avoids a
    /// circular initializer dependency between the two.
    public func setOnOpenSettings(_ handler: @escaping () -> Void) {
        onOpenSettings = handler
    }

    /// Set once by the composition root, same reasoning as
    /// `setOnOpenSettings` — avoids a circular initializer dependency with
    /// the Uninstall panel window controller.
    public func setOnRequestUninstall(_ handler: @escaping (String) -> Void) {
        onRequestUninstall = handler
    }

    /// Set once by the composition root, same reasoning as
    /// `setOnOpenSettings`/`setOnRequestUninstall`.
    public func setOnDidHide(_ handler: @escaping () -> Void) {
        onDidHide = handler
    }

    public func loadGridDocument() async {
        await gridModel.loadDocument()
        // The layout document owns this setting; synchronize the search
        // model before the first catalog snapshot arrives.
        viewModel.setShowMenuBarApplications(gridModel.showMenuBarApplications)
    }

    /// Debug-only — see `AppDelegate`'s `LAUNCHPAD_DEBUG_SEARCH_QUERY` doc
    /// comment for why this exists (driving/screenshotting the search
    /// results layout without Accessibility/GUI-scripting permission).
    public func debugSetSearchQuery(_ query: String) {
        viewController?.debugSetSearchQuery(query)
    }

    /// Debug-only — see `AppDelegate`'s `LAUNCHPAD_DEBUG_CLICK_SEARCH_FIELD`
    /// doc comment.
    public func debugSimulateSearchFieldClick() {
        viewController?.debugSimulateSearchFieldClick()
    }

    /// Debug-only — see `AppDelegate`'s `LAUNCHPAD_DEBUG_TYPE_SEARCH_FIELD`
    /// doc comment (Round 13 §E).
    public func debugSimulateSearchFieldTyping(_ text: String) {
        viewController?.debugSimulateSearchFieldTyping(text)
    }

    /// Debug-only — see `GridViewController.debugSimulatePageDrag`'s doc
    /// comment for why this exists.
    public func debugSimulatePageDrag(commit: Bool) {
        viewController?.debugSimulatePageDrag(commit: commit)
    }

    /// Debug-only — see `GridViewController.debugOpenFolder`'s doc
    /// comment for why this exists.
    public func debugOpenFolder(ordinal: Int) {
        viewController?.debugOpenFolder(ordinal: ordinal)
    }

    /// Debug-only — see `GridViewController.debugSimulateItemDrag`'s doc
    /// comment for why this exists.
    public func debugSimulateItemDrag(mode: String) {
        viewController?.debugSimulateItemDrag(mode: mode)
    }

    /// Exposed so composition-root code (`AppDelegate`, the Settings window)
    /// can read/mutate grid settings, custom sources, hidden apps, and
    /// aliases without this controller growing one pass-through accessor per
    /// concern.
    public var model: GridModel {
        gridModel
    }

    public var triggerSettings: TriggerSettings {
        gridModel.triggerSettings
    }

    public func updateTriggerSettings(_ settings: TriggerSettings) async {
        gridModel.updateTriggerSettings(settings)
        await gridModel.save()
    }

    /// Persists the Hide Dock preference and, if the launcher window
    /// already exists, re-applies its window level immediately — the
    /// window is created lazily on first `show()`, so there isn't always
    /// a live window to update yet, but there's nothing to lose either way
    /// since a freshly-created window already reads the persisted value.
    public func updateDockVisibilityPreference(_ hideDock: Bool) {
        gridModel.setHideDockWhileLauncherOpen(hideDock)
        Task { await gridModel.save() }
        if isVisible {
            setLauncherPresentation(active: true)
        }
        window?.applyDockVisibilityPreference(
            hideDock: hideDock,
            reason: "settings update",
            screenFrame: window?.screen?.frame
        )
        viewController?.refreshDockLayout()
    }

    private func currentBackgroundConfiguration() -> LauncherBackgroundView.Configuration {
        var config = LauncherBackgroundView.Configuration()
        config.mode = gridModel.backgroundMode
        config.materialIntensity = gridModel.glassMaterialIntensity
        config.blursWallpaper = gridModel.blursWallpaper
        return config
    }

    public func updateBackgroundSettings(mode: LauncherBackgroundMode, materialIntensity: Double, blursWallpaper: Bool) {
        var config = LauncherBackgroundView.Configuration()
        config.mode = mode
        config.materialIntensity = materialIntensity
        config.blursWallpaper = blursWallpaper
        backgroundView?.update(configuration: config)
    }

    /// Called when Settings (which floats *above* the launcher without
    /// hiding it — see `SettingsWindowController`'s doc comment) closes —
    /// see `SettingsWindowController.windowWillClose`'s doc comment for the
    /// full explanation of why the launcher does not automatically regain
    /// key status on its own. A no-op if the
    /// launcher isn't currently visible (e.g. the user hid it first, then
    /// closed Settings separately) — nothing to reclaim in that case, and
    /// forcing a hidden window key/front would show it unexpectedly.
    public func reclaimKeyIfVisible() {
        guard let window, window.isVisible else {
            DiagnosticsLog.launcher.info("reclaimKeyIfVisible: bailed (window is nil or not visible)")
            return
        }
        // Confirmed via the `LAUNCHPAD_DEBUG_SETTINGS_KEY_RECLAIM` hook:
        // `makeKeyAndOrderFront` alone didn't stick — closing Settings (an
        // ordinary, activating window) can take the *application* itself
        // out of the active/frontmost state, same as `show()`'s own reason
        // for calling `NSApp.activate` before `makeKeyAndOrderFront` (see
        // that method's doc comment). Without reactivating the app first,
        // asking the launcher window to become key while some other app is
        // frontmost doesn't actually succeed.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        DiagnosticsLog.launcher.info("reclaimKeyIfVisible: requested key, isKeyWindow now \(window.isKeyWindow, privacy: .public)")
    }

    /// Debug-only — see `AppDelegate`'s `LAUNCHPAD_DEBUG_SETTINGS_KEY_RECLAIM`
    /// doc comment.
    public func debugIsWindowKey() -> Bool {
        window?.isKeyWindow ?? false
    }

    /// - Parameter isAuthoritative: `false` when `records` came from the
    ///   startup cache rather than a completed scan — see
    ///   `GridModel.reconcile(with:prunesMissingItems:)` for the grid-
    ///   reshuffling bug that distinction exists to prevent.
    public func updateRecords(_ records: [ApplicationRecord], isAuthoritative: Bool = true) {
        latestRecords = records

        // Legacy import must run BEFORE reconcile: `applyLegacyImportIfFirstRun`
        // only applies when the grid is still completely empty, and
        // `reconcile` itself fills the grid (alphabetically) with anything
        // unplaced — running reconcile first would make every subsequent
        // import attempt see a "non-empty" grid and silently no-op.
        if !hasAttemptedLegacyImport {
            hasAttemptedLegacyImport = true
            if let dbURL = LegacyLaunchpadImporter.defaultDatabaseURL() {
                let result = LegacyLaunchpadImporter.importLegacyLayout(from: dbURL, matching: records)
                if gridModel.applyLegacyImportIfFirstRun(result) {
                    DiagnosticsLog.launcher.info(
                        "Imported legacy Launchpad layout: \(result.folders.count, privacy: .public) folders, \(result.unresolvedBundleIDs.count, privacy: .public) unresolved bundle IDs"
                    )
                }
            }
        }

        if gridModel.reconcile(with: records, prunesMissingItems: isAuthoritative) {
            Task { await gridModel.save() }
        }
        // Reconcile first so search follows the same current page/folder order
        // as the visible grid, including newly imported or moved items.
        applySearchableRecords()
    }

    private func applySearchableRecords() {
        viewModel.setShowMenuBarApplications(gridModel.showMenuBarApplications)
        let orderedRecords = gridModel.orderedRecords(from: latestRecords)
        if gridModel.showsHiddenAppsInSearch {
            viewModel.setRecords(orderedRecords)
        } else {
            let hiddenValues = Set(gridModel.hiddenApplicationIdentifiers.map(\.value))
            viewModel.setRecords(orderedRecords.filter { !hiddenValues.contains($0.id.value) })
        }
    }

    /// Called from Settings when `showsHiddenAppsInSearch` changes, so the
    /// toggle takes effect immediately rather than waiting for the next
    /// catalog scan/FSEvents update.
    public func refreshSearchableRecords() {
        applySearchableRecords()
        viewController?.reloadGrid()
    }

    /// Same-trigger reinvocation closes it; otherwise it opens (or moves to
    /// the current pointer's screen if already open elsewhere).
    public func toggle() {
        if isVisible {
            hide()
        } else {
            show()
        }
    }

    public func show() {
        // Phase 9 measurement: "warm trigger to first frame" — the window
        // already exists on every call after the first, so this number
        // reflects steady-state (warm) open latency, not cold construction.
        let start = DispatchTime.now()
        guard let screen = Self.targetScreen() else {
            DiagnosticsLog.launcher.error("show(): aborted because no NSScreen is available")
            return
        }
        let window = window ?? makeWindow(on: screen)
        let wasVisible = window.isVisible
        // Reopening keeps the warm icon cache — only a launcher that stays
        // closed pays the eviction.
        iconEvictionTask?.cancel()
        iconEvictionTask = nil
        // The resident helper becomes regular only while the overlay is
        // visible; it returns to accessory after the overlay is ordered out.
        guard NSApp.setActivationPolicy(.regular) else {
            DiagnosticsLog.launcher.error("show(): could not switch activation policy to regular")
            return
        }
        // Apply the valid menu-bar/Dock pair before ordering the overlay front.
        setLauncherPresentation(active: true)
        window.setFrame(screen.frame, display: true)
        window.applyDockVisibilityPreference(
            hideDock: gridModel.hideDockWhileLauncherOpen,
            reason: "show before frame",
            screenFrame: screen.frame
        )
        viewController?.resetSearch()

        animationGeneration += 1

        // Only play the entrance animation on an actual hidden->shown
        // transition — real Launchpad semantics route the pinch gesture
        // straight to show() (not toggle()), so a redundant pinch while
        // already open must just refocus, not replay the animation.
        if !wasVisible {
            rootContentView?.layer?.removeAllAnimations()
            window.alphaValue = 0
        }

        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        // An accessory app can be ordered while another app owns a fullscreen
        // Space. `makeKeyAndOrderFront` alone may leave the window attached to
        // that non-active Space; explicitly ordering it regardless of app
        // activation keeps this overlay on the current display/Space.
        window.orderFrontRegardless()
        // This is a same-desktop overlay, not an AppKit fullscreen
        // transition. Animate immediately so a missing WindowServer callback
        // can never leave the window at alpha 0 (the previous black-screen
        // failure mode).
        refreshOverlayLayout(reason: "show overlay")
        // Materialize the first cells while the window is still transparent,
        // then rebuild them with the settled layout metrics.
        viewController?.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        viewController?.reloadGrid()
        viewController?.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        // Do not rely on CA's animator to perform the first visibility
        // transition. If the window was ordered while the app was changing
        // activation policy, the animation transaction can be deferred and
        // leave the whole-screen window at alpha 0. Make the visible state
        // authoritative first, then add the cosmetic animation.
        window.alphaValue = 1
        if !wasVisible { animateIn(window: window) }

        DiagnosticsLog.launcher.info("show(): after makeKeyAndOrderFront, isVisible=\(window.isVisible, privacy: .public), isKeyWindow=\(window.isKeyWindow, privacy: .public), windowFrame=\(String(describing: window.frame), privacy: .public), screenFrame=\(String(describing: screen.frame), privacy: .public), optionsRaw=\(NSApp.presentationOptions.rawValue, privacy: .public), currentSystemOptionsRaw=\(NSApp.currentSystemPresentationOptions.rawValue, privacy: .public), isActive=\(NSApp.isActive, privacy: .public), frontmostPID=\(Self.frontmostPID, privacy: .public)")

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        DiagnosticsLog.launcher.info("warm open: trigger to makeKeyAndOrderFront took \(ms, privacy: .public)ms")
    }

    public func hide() {
        guard let window, window.isVisible else {
            setLauncherPresentation(active: false)
            _ = NSApp.setActivationPolicy(.accessory)
            return
        }
        onDidHide?()
        animationGeneration += 1
        let generation = animationGeneration

        if let layer = rootContentView?.layer {
            layer.removeAllAnimations()
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DMakeScale(0.94, 0.94, 1)
            CATransaction.commit()
            layer.add(Self.springAnimation(keyPath: "transform.scale", from: 1.0, to: 0.94, damping: 1.0, response: 0.28), forKey: "scaleOut")
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.30
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            window.animator().alphaValue = 0
        }, completionHandler: { [weak self, weak window] in
            // `NSAnimationContext`'s completion handler type isn't
            // `@MainActor`-annotated in the SDK, so the compiler can't see
            // that this always actually runs on the main thread — hop
            // explicitly rather than accessing main-actor state from a
            // nominally-Sendable closure.
            Task { @MainActor in
                guard let self, self.animationGeneration == generation, let window else { return }
                self.finishHide(window: window, generation: generation)
            }
        })
    }

    /// Uses a short opacity transition only. A root scale animation changes
    /// every icon and label while the first layout is settling, which made a
    /// correct grid look like it grew and then shrank. Geometry must remain
    /// authoritative; animation is limited to visibility.
    private func animateIn(window: NSWindow) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
    }

    private func finishHide(window: LauncherWindow, generation: Int) {
        guard animationGeneration == generation else { return }
        window.orderOut(nil)
        setLauncherPresentation(active: false)
        _ = NSApp.setActivationPolicy(.accessory)
        window.alphaValue = 1
        if let layer = rootContentView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
        }
        refreshOverlayLayout(reason: "hide completed")
        scheduleIconCacheEviction()
    }

    /// Releases the decoded-icon memory cache once the launcher has stayed
    /// hidden for a while. `IconCache` bounds itself at 192 entries, which its
    /// own comment puts at roughly 48 MiB of 2x RGBA pixels, and nothing ever
    /// called `evictMemoryCache()` — so a resident menu-bar app that the user
    /// opens once keeps that memory for the rest of the session, and
    /// `prefetchAdjacentPageIcons` keeps refilling it. Eviction is delayed
    /// rather than immediate because reopening within a few seconds is the
    /// common case and should stay instant; the disk cache also survives, so
    /// even a post-eviction reopen re-decodes rather than re-renders from
    /// scratch.
    private func scheduleIconCacheEviction() {
        iconEvictionTask?.cancel()
        iconEvictionTask = Task { @MainActor [weak self] in
            do {
                try await Task.sleep(nanoseconds: Self.iconEvictionDelayNanoseconds)
            } catch {
                return
            }
            guard let self, !Task.isCancelled else { return }
            self.iconCache.evictMemoryCache()
            WallpaperImageCache.evictAll()
            self.window?.contentViewController = nil
            self.window?.delegate = nil
            self.window = nil
            self.viewController = nil
            self.rootContentView = nil
            self.backgroundView = nil
            DiagnosticsLog.launcher.info("hidden launcher UI and image caches released after idle")
            self.iconEvictionTask = nil
        }
    }

    /// Builds a `CASpringAnimation` from Apple's damping-ratio/response
    /// parameters (see apple-design's spring guidance) rather than the raw
    /// mass/stiffness/damping triplet `CASpringAnimation` actually takes —
    /// `mass` is fixed at 1, so `stiffness = (2π/response)²` and
    /// `damping = 2 × dampingRatio × sqrt(stiffness)`.
    private static func springAnimation(keyPath: String, from: CGFloat, to: CGFloat, damping dampingRatio: CGFloat, response: CGFloat) -> CASpringAnimation {
        let animation = CASpringAnimation(keyPath: keyPath)
        let angularFrequency = 2 * .pi / response
        let stiffness = angularFrequency * angularFrequency
        animation.mass = 1
        animation.stiffness = stiffness
        animation.damping = 2 * dampingRatio * sqrt(stiffness)
        animation.initialVelocity = 0
        animation.fromValue = from
        animation.toValue = to
        animation.duration = animation.settlingDuration
        return animation
    }

    private func makeWindow(on screen: NSScreen) -> LauncherWindow {
        let window = LauncherWindow(contentRect: screen.frame, hideDock: gridModel.hideDockWhileLauncherOpen)
        window.delegate = self
        window.onCancel = { [weak self] in self?.viewController?.cancelSearchOrDismiss() }
        window.onCloseWindow = { [weak self] in self?.hide() }
        window.onOpenSettings = { [weak self] in self?.onOpenSettings?() }
        window.onFocusSearch = { [weak self] in self?.viewController?.focusSearch() }

        // Hidden-app mutations can originate from the grid's context menu,
        // not only Settings. Attach a dedicated observer so an active search
        // query reflects hide/unhide immediately without waiting for a scan.
        gridModel.onHiddenApplicationsChange = { [weak self] in
            self?.refreshSearchableRecords()
        }

        let content = LauncherViewController(
            viewModel: viewModel,
            gridModel: gridModel,
            iconCache: iconCache,
            onDidLaunch: { [weak self] in self?.hide() },
            onDidCancel: { [weak self] in self?.hide() },
            onOpenSettings: { [weak self] in
                self?.onOpenSettings?()
            },
            onRequestUninstall: { [weak self] bundleIdentifier in
                self?.onRequestUninstall?(bundleIdentifier)
            }
        )

        let root = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
        // Backs the open/close scale animation — animated on `root`'s own
        // layer, a level above `background`/`content.view`, so scaling
        // never fights with either of their own layer usage.
        root.wantsLayer = true
        let background = LauncherBackgroundView(
            screen: screen,
            configuration: currentBackgroundConfiguration()
        )
        background.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(background)
        backgroundView = background

        content.view.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(content.view)

        NSLayoutConstraint.activate([
            background.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            background.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            background.topAnchor.constraint(equalTo: root.topAnchor),
            background.bottomAnchor.constraint(equalTo: root.bottomAnchor),

            content.view.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            content.view.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            content.view.topAnchor.constraint(equalTo: root.topAnchor),
            content.view.bottomAnchor.constraint(equalTo: root.bottomAnchor)
        ])

        let containerController = NSViewController()
        containerController.view = root
        window.contentViewController = containerController

        self.window = window
        self.viewController = content
        self.rootContentView = root
        startOutsideClickMonitorIfNeeded()
        return window
    }

    /// `windowDidResignKey` alone turned out to be an unreliable dismiss
    /// signal for a full-screen launcher window (clicking another app's
    /// window didn't reliably resign key status during hands-on testing). A global
    /// mouse-down monitor is an explicit, direct signal: any click that
    /// lands outside this window's frame while it's visible closes it,
    /// independent of key-window bookkeeping.
    private var outsideClickMonitor: Any?
    private var appActivationObserver: Any?

    private func startOutsideClickMonitorIfNeeded() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self else { return }
                DiagnosticsLog.launcher.info("outsideClickMonitor fired, isVisible=\(self.isVisible, privacy: .public)")
                guard self.isVisible else { return }
                self.hide()
            }
        }
        DiagnosticsLog.launcher.info("outsideClickMonitor installed: \(self.outsideClickMonitor != nil, privacy: .public)")
        guard appActivationObserver == nil else { return }
        appActivationObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let activatedApp = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            let activatedBundleID = activatedApp?.bundleIdentifier ?? "?"
            let isThisApp = activatedApp?.processIdentifier == ProcessInfo.processInfo.processIdentifier

            Task { @MainActor [weak self] in
                guard let self else { return }
                DiagnosticsLog.launcher.info("appActivationObserver fired: activatedBundleID=\(activatedBundleID, privacy: .public), isThisApp=\(isThisApp, privacy: .public), isVisible=\(self.isVisible, privacy: .public)")
                guard self.isVisible, !isThisApp else { return }
                self.hide()
            }
        }
    }

    /// "ポインタまたはアクティブウインドウが存在するディスプレイ" — the
    /// pointer's screen is checked first; if that lookup fails for any
    /// reason, fall back to the key window's screen, then the main screen.
    private static func targetScreen() -> NSScreen? {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return screen
        }
        if let keyScreen = NSApp.keyWindow?.screen {
            return keyScreen
        }
        if let mainScreen = NSScreen.main {
            return mainScreen
        }
        guard let fallbackScreen = NSScreen.screens.first else {
            DiagnosticsLog.launcher.error("targetScreen(): no NSScreen is available")
            return nil
        }
        return fallbackScreen
    }

    // MARK: NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        guard !NSApp.isActive else {
            DiagnosticsLog.launcher.info("windowDidResignKey fired, but app is still active (key moved to another of this app's windows) — not hiding")
            return
        }
        DiagnosticsLog.launcher.info("windowDidResignKey fired, app resigned active — hiding")
        hide()
    }

    public func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? LauncherWindow else { return }
        guard window.isVisible else { return }
        setLauncherPresentation(active: true)
        window.applyDockVisibilityPreference(
            hideDock: gridModel.hideDockWhileLauncherOpen,
            reason: "windowDidBecomeKey",
            screenFrame: window.screen?.frame
        )
    }

    public func windowDidChangeScreen(_ notification: Notification) {
        guard let window = notification.object as? LauncherWindow else { return }
        guard window.isVisible else { return }
        setLauncherPresentation(active: true)
        window.applyDockVisibilityPreference(
            hideDock: gridModel.hideDockWhileLauncherOpen,
            reason: "windowDidChangeScreen",
            screenFrame: window.screen?.frame
        )
        refreshOverlayLayout(reason: "did change screen")
    }
}
