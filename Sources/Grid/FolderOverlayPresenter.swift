import AppKit
import Catalog
import Diagnostics
import Persistence

/// Presents an opened folder as a full-screen dimmed take-over.
///
/// Split out of `GridViewController` because none of it touches the grid's
/// own state: it owns a backdrop, a blur, a tint and a
/// `FolderContentsViewController`, and the grid only ever asks it to open or
/// close. Everything the panel needs from the grid — where to host it, how big
/// its icons are, what to do on launch or drag-out — arrives as parameters, so
/// the two can be read independently.
///
/// The presentation is a full-screen dimmed take-over, matching the
/// user-supplied design reference's own `FolderOverlay` exactly (explicit
/// request: "フォルダ名の中身は全画面で表示されるzipのやつにして") — a small
/// anchored `NSPopover` (this project's prior, safer choice) was rejected as
/// not matching. `FolderContentsViewController` and all of its already-proven
/// AppKit interaction code (click-to-launch, right-click context menu,
/// drag-out-to-remove) stay completely unchanged — only the *presentation
/// container* differs, which is what kept a purely visual change from
/// re-risking interaction logic fixed several times in this project's history.
@MainActor
final class FolderOverlayPresenter {
    /// What the panel needs to know about the grid it was opened from, so its
    /// mosaic and card size follow the same scale the grid is currently drawn
    /// at rather than a second, independently-derived one.
    struct Metrics {
        /// Already multiplied by the grid's effective visual scale. The open
        /// folder's tiles are SwiftUI content rather than `GridCellItem`, so
        /// they never receive the cell layer transform that scale is otherwise
        /// applied through.
        let iconSize: Double
        let configuredColumns: Int
    }

    private let model: GridModel
    private let iconCache: IconCache
    private var backdrop: FolderOverlayBackdropView?
    /// Held for lifetime only — the panel's view is in the backdrop's
    /// subview tree, but nothing else retains the controller behind it.
    private var contentsViewController: FolderContentsViewController?

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
    func open(
        _ folderID: FolderID,
        in hostView: NSView,
        metrics: Metrics,
        onLaunch: @escaping (ApplicationRecord) -> Void,
        onItemDraggedOut: @escaping (Int, Int) -> Void
    ) {
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
        let panelWidth = FolderContentsViewController.panelWidth(
            availableWidth: hostView.bounds.width - 192,
            columns: folderColumns,
            iconSize: CGFloat(metrics.iconSize)
        )

        let folderVC = FolderContentsViewController(
            model: model,
            folderID: folderID,
            iconCache: iconCache,
            iconSize: metrics.iconSize,
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

        // Blurs the grid behind the overlay, then darkens on top — matches
        // the reference's `blur(22px)` + `rgba(8,8,9,.55)` exactly (a flat
        // dim color alone, the previous implementation, left the grid
        // sharply visible underneath instead of visibly blurred).
        let blur = NonInteractiveFolderBlurView(frame: backdrop.bounds)
        blur.autoresizingMask = [.width, .height]
        blur.material = .fullScreenUI
        blur.blendingMode = .withinWindow
        blur.state = .active
        backdrop.addSubview(blur)

        let tint = NSView(frame: backdrop.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.55).cgColor
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

        // `panel` is positioned via a direct, one-time frame assignment —
        // not Auto Layout constraints — see `FolderContentsViewController
        // .loadView()`'s doc comment for why (a real, confirmed regression
        // where AppKit's own `preferredContentSize`-mirrored width
        // constraint intermittently won over an explicit Auto Layout
        // constraint of equal or higher priority). `backdrop`'s eventual
        // size is already known here without waiting for its own Auto
        // Layout resolution: it's pinned 1:1 to `hostView`'s edges above, so
        // its size always equals `hostView.bounds.size` (already read into
        // `panelWidth`). 96pt side insets match the reference's own
        // `.padding(.horizontal, TSLayout.folderPanelInsetH)` exactly.
        //
        // Vertically centered on screen rather than the reference's own
        // literal fixed `.padding(.top, 196)` — a real, confirmed complaint
        // ("画面の中央からずれてる"): the reference's fixed offset assumes a
        // card tall enough to roughly fill the remaining space below it,
        // but for a folder with only a couple of rows the card ends up far
        // short of the 480pt height cap, leaving a much bigger gap below
        // the card than above it — reading as pushed toward the top rather
        // than centered. True vertical centering keeps the composition
        // balanced regardless of how many rows the folder actually has,
        // and matches the broader macOS convention of centering modal-style
        // overlays (Quick Look, alerts, About panels) rather than pinning
        // them to a fixed offset tuned for one specific content size.
        let backdropSize = hostView.bounds.size
        panel.frame = NSRect(
            x: (backdropSize.width - size.width) / 2,
            y: (backdropSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        // Forces `root`'s internal Auto Layout children (title/scroll view/
        // hosted SwiftUI grid, all pinned to `root`'s now-final frame) to
        // resolve synchronously against that frame before the entrance
        // animation starts, rather than depending on some later, unrelated
        // event (an async icon load's own `layoutIfNeeded()` call) to
        // eventually force the correct layout — the same class of
        // intermittent race already fixed once for the icon-trickle case in
        // `FolderContentsViewController.refresh()`.
        panel.layoutSubtreeIfNeeded()

        self.backdrop?.removeFromSuperview()
        self.backdrop = backdrop
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

    override func keyDown(with event: NSEvent) {
        // Routes Escape/arrows through the standard action selectors above
        // rather than matching key codes by hand.
        interpretKeyEvents([event])
    }
}

/// Blurs the live grid content behind the folder overlay — matching the
/// design reference's own mockup
/// (`background:rgba(8,8,9,.55);backdrop-filter:blur(22px)`), which shows
/// the grid as visibly *blurred and darkened*, not just darkened. A purely
/// decorative background must never intercept clicks (same reasoning as
/// `Launcher.NonInteractiveVisualEffectView`, which this file can't import
/// across the module boundary — `Grid` sits below `Launcher` — so this is a
/// local copy of the same one-line fix): overriding `hitTest` to
/// unconditionally return `nil` lets every click fall through to
/// `FolderOverlayBackdropView.mouseDown` (the actual dismiss handler)
/// regardless of this view sitting on top of it in z-order.
private final class NonInteractiveFolderBlurView: NSVisualEffectView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}
