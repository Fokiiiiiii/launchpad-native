import AppKit
import Catalog
import Diagnostics
import Persistence

/// Presents an opened folder over a dimmed grid.
///
/// Split out of `GridViewController` because none of it touches the grid's own
/// state: everything the panel needs arrives as parameters. Only the
/// presentation container lives here — `FolderContentsViewController`'s
/// interaction code (click-to-launch, context menu, drag-out) is untouched by
/// visual changes, which is what has kept them from re-breaking it.
@MainActor
final class FolderOverlayPresenter {
    /// What the panel needs from the grid, so its sizing follows the scale the
    /// grid is currently drawn at rather than a second derivation.
    struct Metrics {
        /// Already multiplied by the grid's visual scale: the folder's tiles
        /// are SwiftUI and never receive the cell layer transform.
        let iconSize: Double
        let configuredColumns: Int
    }

    /// Margin between the panel and the screen edges.
    private static let panelSideInset: CGFloat = 96

    private let model: GridModel
    private let iconCache: IconCache
    private var backdrop: FolderOverlayBackdropView?
    /// Held for lifetime only — the panel's view is in the backdrop's
    /// subview tree, but nothing else retains the controller behind it.
    private var contentsViewController: FolderContentsViewController?
    private var onDidCloseHandler: (() -> Void)?

    /// Test hook: the panel is held only here, and losing that hold once left
    /// every async icon load resolving against a dead controller.
    var presentedPanelForTesting: FolderContentsViewController? { contentsViewController }

    init(model: GridModel, iconCache: IconCache) {
        self.model = model
        self.iconCache = iconCache
    }

    /// - Parameter hostView: The view the backdrop covers. The caller picks it
    ///   because the right answer depends on the grid's own view structure —
    ///   see `GridViewController.openFolder`.
    /// - Parameter onItemDraggedOut: Receives the folder-local page and index
    ///   of an item dragged out of the panel. Handled by the caller rather than
    ///   here because where the item lands depends on the grid's current page.
    /// - Parameter onDidClose: Fires once the panel is actually gone, so the
    ///   caller can restore whatever it hid while the folder was open.
    func open(
        _ folderID: FolderID,
        in hostView: NSView,
        metrics: Metrics,
        onLaunch: @escaping (ApplicationRecord) -> Void,
        onItemDraggedOut: @escaping (Int, Int) -> Void,
        onDidClose: @escaping () -> Void
    ) {
        onDidCloseHandler = onDidClose
        let start = DispatchTime.now()
        guard model.folders[folderID] != nil else { return }

        // The fullest page, not the folder's total: the panel shows one page at
        // a time, and its shape must not change as the user pages through.
        let itemCount = model.folders[folderID]?.pages.map(\.count).max() ?? 0
        let configuredColumns = max(metrics.configuredColumns, 1)
        let folderColumns = FolderContentsViewController.displayedColumnCount(
            itemCount: itemCount,
            configuredColumns: configuredColumns
        )
        let rows = max(Int(ceil(Double(itemCount) / Double(folderColumns))), 1)
        let iconSize = FolderContentsViewController.folderIconSize(
            gridIconSize: metrics.iconSize,
            rows: rows,
            availableHeight: hostView.bounds.height
        )
        let panelWidth = FolderContentsViewController.panelWidth(
            availableWidth: hostView.bounds.width - 2 * Self.panelSideInset,
            columns: folderColumns,
            iconSize: CGFloat(iconSize)
        )

        let folderVC = FolderContentsViewController(
            model: model,
            folderID: folderID,
            iconCache: iconCache,
            iconSize: iconSize,
            columns: folderColumns,
            panelWidth: panelWidth,
            maximumHeight: FolderContentsViewController.maximumPanelHeight(
                availableHeight: hostView.bounds.height
            ),
            onLaunch: { [weak self] record in
                self?.close()
                onLaunch(record)
            },
            onItemDraggedOut: onItemDraggedOut
        )
        folderVC.loadViewIfNeeded()

        let backdrop = FolderOverlayBackdropView()
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        backdrop.onDismiss = { [weak self] in self?.close() }
        // The backdrop is first responder while a folder is open (that is what
        // makes Escape work), so arrow keys arrive here rather than at the
        // panel that acts on them.
        backdrop.onArrowKey = { [weak self] delta in
            self?.contentsViewController?.handleArrowKey(delta: delta) ?? false
        }
        backdrop.onVerticalArrowKey = { [weak self] delta in
            self?.contentsViewController?.handleVerticalArrowKey(delta: delta) ?? false
        }
        backdrop.onActivateSelection = { [weak self] in
            self?.contentsViewController?.activateSelection() ?? false
        }

        // Sinks the grid back without hiding it. The panel itself is a light,
        // legible surface, so it separates from what is behind it without
        // needing the near-blackout this used when it was a card taking over
        // the whole screen.
        let tint = NSView(frame: backdrop.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.28).cgColor
        backdrop.addSubview(tint)

        let panel = folderVC.view
        backdrop.addSubview(panel)
        hostView.addSubview(backdrop)

        let size = folderVC.preferredContentSize
        NSLayoutConstraint.activate([
            backdrop.topAnchor.constraint(equalTo: hostView.topAnchor),
            backdrop.leadingAnchor.constraint(equalTo: hostView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: hostView.trailingAnchor),
            backdrop.bottomAnchor.constraint(equalTo: hostView.bottomAnchor)
        ])

        let backdropSize = hostView.bounds.size
        panel.frame = Self.panelFrame(size: size, in: backdropSize)
        // Forces `root`'s internal Auto Layout children to resolve against that
        // frame before the entrance animation starts, rather than depending on
        // some later, unrelated event to eventually force the correct layout.
        panel.layoutSubtreeIfNeeded()

        self.backdrop?.removeFromSuperview()
        self.backdrop = backdrop
        // Load-bearing: only the backdrop holds the panel's *view*, nothing
        // holds the controller. Without this it deallocates immediately and
        // every async icon load resolves against a dead `self`, leaving the
        // folder full of blank placeholders.
        contentsViewController = folderVC
        hostView.window?.makeFirstResponder(backdrop)

        backdrop.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.16
            backdrop.animator().alphaValue = 1
        }

        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        DiagnosticsLog.launcher.info("folder transition: build+show full-screen overlay took \(ms, privacy: .public)ms")
    }

    /// Centered on screen, at whatever size its contents came to.
    ///
    /// An earlier pass anchored it below the folder icon with a notch. At this
    /// grid's icon sizes a deep folder does not fit below its own icon, so it
    /// ended up pinned to the top with the icon buried inside it.
    static func panelFrame(size: NSSize, in hostSize: NSSize) -> NSRect {
        NSRect(
            x: (hostSize.width - size.width) / 2,
            y: (hostSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
    }

    func close() {
        guard let backdrop else { return }
        self.backdrop = nil
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.14
            backdrop.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            Task { @MainActor [weak self] in
                backdrop.removeFromSuperview()
                self?.contentsViewController = nil
                self?.onDidCloseHandler?()
                self?.onDidCloseHandler = nil
            }
        })
    }
}

/// Full-bounds dimming backdrop for the opened-folder overlay. Clicking
/// anywhere on the backdrop itself dismisses — clicks on the folder panel (a
/// subview added on top) never reach here at all, since AppKit hit-tests
/// subviews before their parent, so the panel's own click-to-launch/context-
/// menu handling is completely unaffected. Also intercepts Escape
/// (`cancelOperation`, standard AppKit convention for the Escape key) so it
/// closes just the folder overlay rather than propagating up to the launcher
/// window's own Escape-hides-the-whole-launcher handling — this view must be
/// made first responder when shown for that interception to actually happen
/// (see `FolderOverlayPresenter.open`).
private final class FolderOverlayBackdropView: NSView {
    var onDismiss: (() -> Void)?
    /// Returns whether the panel consumed the key, so an unhandled arrow still
    /// falls through to whatever would normally have received it.
    var onArrowKey: ((Int) -> Bool)?
    /// Up/down move the keyboard selection between rows; Return opens what is
    /// selected. Same "did the panel take it" contract as `onArrowKey`.
    var onVerticalArrowKey: ((Int) -> Bool)?
    var onActivateSelection: (() -> Bool)?

    override var acceptsFirstResponder: Bool { true }

    override func mouseDown(with event: NSEvent) {
        onDismiss?()
    }

    override func cancelOperation(_ sender: Any?) {
        onDismiss?()
    }

    override func moveLeft(_ sender: Any?) {
        if onArrowKey?(-1) != true { super.moveLeft(sender) }
    }

    override func moveRight(_ sender: Any?) {
        if onArrowKey?(1) != true { super.moveRight(sender) }
    }

    override func moveUp(_ sender: Any?) {
        if onVerticalArrowKey?(-1) != true { super.moveUp(sender) }
    }

    override func moveDown(_ sender: Any?) {
        if onVerticalArrowKey?(1) != true { super.moveDown(sender) }
    }

    override func insertNewline(_ sender: Any?) {
        if onActivateSelection?() != true { super.insertNewline(sender) }
    }

    override func keyDown(with event: NSEvent) {
        // Routes Escape/arrows through the standard action selectors above
        // rather than matching key codes by hand.
        interpretKeyEvents([event])
    }
}
