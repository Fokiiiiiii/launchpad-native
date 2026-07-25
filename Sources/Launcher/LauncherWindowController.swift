import AppKit
import Catalog
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
    private let viewModel = LauncherViewModel()
    private let gridModel: GridModel
    private let iconCache: IconCache
    private var hasAttemptedLegacyImport = false
    private var onOpenSettings: (() -> Void)?
    private var onRequestUninstall: ((String) -> Void)?
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

    /// Reads the window's own real visibility rather than a separately
    /// tracked bool — a manually-maintained `isVisible` flag drifted out of
    /// sync with the actual window state during hands-on testing (e.g. the
    /// outside-click monitor kept seeing a stale `false` while the window
    /// was still genuinely on screen, so clicking outside silently did
    /// nothing). `NSWindow.isVisible` is always the ground truth.
    private var isVisible: Bool {
        window?.isVisible ?? false
    }

    public init(iconCache: IconCache, layoutStore: LayoutStore) {
        self.iconCache = iconCache
        self.gridModel = GridModel(layoutStore: layoutStore)
        super.init()
    }

    /// Set once by the composition root (`AppDelegate`) after both this
    /// controller and the Settings window controller exist — avoids a
    /// circular initializer dependency between the two.
    public func setOnOpenSettings(_ handler: @escaping () -> Void) {
        onOpenSettings = handler
    }

    /// Set once by the composition root, same reasoning as
    /// `setOnOpenSettings` — avoids a circular initializer dependency with
    /// the Settings window controller.
    public func setOnRequestUninstall(_ handler: @escaping (String) -> Void) {
        onRequestUninstall = handler
    }

    public func loadGridDocument() async {
        await gridModel.loadDocument()
    }

    /// Debug-only — see `AppDelegate`'s `LAUNCHPAD_DEBUG_SEARCH_QUERY` doc
    /// comment for why this exists (driving/screenshotting the search
    /// results layout without Accessibility/GUI-scripting permission).
    public func debugSetSearchQuery(_ query: String) {
        viewController?.debugSetSearchQuery(query)
    }

    /// Debug-only — see `GridViewController.debugSimulatePageDrag`'s doc
    /// comment for why this exists.
    public func debugSimulatePageDrag() {
        viewController?.debugSimulatePageDrag()
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

    public func updateRecords(_ records: [ApplicationRecord]) {
        viewModel.setRecords(records)

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

        gridModel.reconcile(with: records)
        viewController?.reloadGrid()
        Task { await gridModel.save() }
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
        let screen = Self.targetScreen()
        let window = window ?? makeWindow(on: screen)
        let wasVisible = window.isVisible
        window.setFrame(screen.frame, display: true)
        viewController?.resetSearch()

        animationGeneration += 1

        // Only play the entrance animation on an actual hidden->shown
        // transition — real Launchpad semantics route the pinch gesture
        // straight to show() (not toggle()), so a redundant pinch while
        // already open must just refocus, not replay the animation.
        if !wasVisible {
            rootContentView?.layer?.removeAllAnimations()
            window.alphaValue = 0
            if let layer = rootContentView?.layer {
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                layer.transform = CATransform3DMakeScale(0.90, 0.90, 1)
                CATransaction.commit()
            }
        }

        // Activate the app *before* asking the panel to become key — doing
        // it in the other order (as a prior version did) let `activate`
        // reassign key status right after `makeKeyAndOrderFront`, which
        // showed up live as the launcher opening and immediately resigning
        // key (closing itself) within ~50ms of every trigger firing.
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)

        if !wasVisible {
            animateIn(window: window)
        }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        DiagnosticsLog.launcher.info("warm open: trigger to makeKeyAndOrderFront took \(ms, privacy: .public)ms")
    }

    public func hide() {
        guard let window, window.isVisible else { return }
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
                window.orderOut(nil)
                // Reset to the resting state so the next show() starts clean —
                // this only runs if nothing interrupted this close (the
                // generation check above), so it never clobbers a reopen.
                window.alphaValue = 1
                if let layer = self.rootContentView?.layer {
                    CATransaction.begin()
                    CATransaction.setDisableActions(true)
                    layer.transform = CATransform3DIdentity
                    CATransaction.commit()
                }
            }
        })
    }

    /// Fade + a gently under-damped "settle" scale, closer to iOS/iPadOS's
    /// own app-open and sheet-presentation motion (noticeably longer than a
    /// UI micro-transition, with a small overshoot as it lands) than the
    /// stricter apple-design default of "no bounce without gesture
    /// momentum" — the user explicitly asked for this to read more like
    /// iPhone/iPad, so damping loosens to 0.82 rather than staying
    /// critically damped at 1.0.
    ///
    /// The alpha fade used to run over the *same* 0.45s as the scale
    /// spring — meaning for the first ~100-150ms after a trigger fires, the
    /// window was still nearly transparent, which read as "nothing
    /// happened yet" (confirmed via a real user report that opening felt
    /// laggy after a pinch gesture, even though gesture recognition itself
    /// is near-instant — traced via code review of
    /// `MultitouchGestureTrigger`/`PinchGestureRecognizer`, which hop to the
    /// main actor and call `show()` synchronously with no delay of their
    /// own). apple-design's response/behavior split applies directly here:
    /// the *fade* is the "did anything happen" signal and needs to resolve
    /// almost immediately, while the *scale*'s longer, slightly bouncy
    /// settle is "behavior" that can keep running after the window already
    /// reads as present.
    private func animateIn(window: NSWindow) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            window.animator().alphaValue = 1
        }
        if let layer = rootContentView?.layer {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            layer.transform = CATransform3DIdentity
            CATransaction.commit()
            layer.add(Self.springAnimation(keyPath: "transform.scale", from: 0.90, to: 1.0, damping: 0.82, response: 0.45), forKey: "scaleIn")
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
        let window = LauncherWindow(contentRect: screen.frame)
        window.delegate = self
        window.onCancel = { [weak self] in self?.hide() }

        let content = LauncherViewController(
            viewModel: viewModel,
            gridModel: gridModel,
            iconCache: iconCache,
            onDidLaunch: { [weak self] in self?.hide() },
            onDidCancel: { [weak self] in self?.hide() },
            onOpenSettings: { [weak self] in
                self?.hide()
                self?.onOpenSettings?()
            },
            onRequestUninstall: { [weak self] bundleIdentifier in
                self?.hide()
                self?.onRequestUninstall?(bundleIdentifier)
            }
        )

        // The glass background is a plain sibling subview behind the real
        // content — not a container for it — so normal AppKit hit-testing
        // applies to every button/cell. See GlassBackgroundView.swift's doc
        // comment for why (NSGlassEffectView.contentView broke mouse events).
        let root = NSView(frame: screen.frame)
        // Backs the open/close scale animation — animated on `root`'s own
        // layer, a level above `background`/`content.view`, so scaling
        // never fights with either of their own layer usage.
        root.wantsLayer = true
        let background = GlassBackgroundFactory.makeBackground(cornerRadius: 0)
        background.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(background)

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
    /// signal for a `.nonactivatingPanel` (clicking another app's window
    /// didn't reliably resign key status during hands-on testing). A global
    /// mouse-down monitor is an explicit, direct signal: any click that
    /// lands outside this window's frame while it's visible closes it,
    /// independent of key-window bookkeeping.
    private var outsideClickMonitor: Any?

    private func startOutsideClickMonitorIfNeeded() {
        guard outsideClickMonitor == nil else { return }
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else { return }
            DiagnosticsLog.launcher.info("outsideClickMonitor fired, isVisible=\(self.isVisible, privacy: .public)")
            guard self.isVisible else { return }
            self.hide()
        }
        DiagnosticsLog.launcher.info("outsideClickMonitor installed: \(self.outsideClickMonitor != nil, privacy: .public)")
    }

    /// "ポインタまたはアクティブウインドウが存在するディスプレイ" — the
    /// pointer's screen is checked first; if that lookup fails for any
    /// reason, fall back to the key window's screen, then the main screen.
    private static func targetScreen() -> NSScreen {
        let mouseLocation = NSEvent.mouseLocation
        if let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) {
            return screen
        }
        if let keyScreen = NSApp.keyWindow?.screen {
            return keyScreen
        }
        return NSScreen.main ?? NSScreen.screens[0]
    }

    // MARK: NSWindowDelegate

    public func windowDidResignKey(_ notification: Notification) {
        // Clicking another app or the desktop resigns key — that's the
        // "click outside" close condition. A click on the launcher's own
        // empty background is handled separately by
        // `BackgroundClickCatcherView`, since that click stays inside this
        // window and never resigns key.
        DiagnosticsLog.launcher.info("windowDidResignKey fired")
        hide()
    }
}
