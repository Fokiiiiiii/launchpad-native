import AppKit
import Catalog
import Diagnostics
import Persistence

/// Presents an opened folder as a screen-wide band over a dimmed grid.
///
/// Split out of `GridViewController` because none of it touches the grid's own
/// state: it owns a backdrop, a tint, a notch and a
/// `FolderContentsViewController`, and the grid only ever asks it to open or
/// close. Everything the panel needs from the grid — where to host it, how big
/// its icons are, which icon it came from, what to do on launch or drag-out —
/// arrives as parameters, so the two can be read independently.
///
/// The shape follows the system's own Launchpad: a band spanning the screen
/// that grows out of the folder icon, rather than a card centered over a fully
/// dimmed screen (this app's previous form, itself replacing an even earlier
/// anchored `NSPopover`). `bandPlacement` decides where it actually lands, and
/// whether pointing a notch at the icon is honest there.
///
/// `FolderContentsViewController` and its already-proven AppKit interaction
/// code (click-to-launch, right-click context menu, drag-out-to-remove) are not
/// involved in any of this — only the presentation container is, which is what
/// has repeatedly kept visual changes here from re-risking interaction logic
/// fixed several times in this project's history.
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
        /// The folder icon's rect in the host's coordinates, so the band can
        /// point back at what opened it. `nil` when the cell is not realized
        /// (a debug hook, or a folder reached from search), in which case the
        /// band centers itself and draws no notch.
        let anchorIconFrame: NSRect?
    }

    /// Smallest margin left between the panel and the screen edges. The panel
    /// is normally far narrower than this allows — it is sized to its contents
    /// — but a folder wide enough to reach the edges stops here.
    private static let bandSideInset: CGFloat = 96
    /// Gap between the folder icon and the top of the band, leaving room for
    /// the notch that spans it.
    private static let notchHeight: CGFloat = 13
    private static let notchWidth: CGFloat = 30
    /// Kept clear of the screen edges when a folder near the top or bottom of
    /// the grid would otherwise push the band off-screen.
    private static let bandScreenMargin: CGFloat = 24

    private let model: GridModel
    private let iconCache: IconCache
    private var backdrop: FolderOverlayBackdropView?
    /// Held for lifetime only — the panel's view is in the backdrop's
    /// subview tree, but nothing else retains the controller behind it.
    private var contentsViewController: FolderContentsViewController?
    private var bandNotch: NSView?

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
        // Sized to what it holds, at the icon size the grid is currently drawn
        // at — not to the screen. A screen-wide band (tried first, following
        // the system's own shape) reads as mostly empty around a folder with a
        // couple of apps in it, and the icon size the user picked is exactly
        // what should decide how much room those apps need.
        let panelWidth = FolderContentsViewController.panelWidth(
            availableWidth: hostView.bounds.width - 2 * Self.bandSideInset,
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

        // Dims the grid without hiding it. The system's own folder panel leaves
        // the apps behind it recognisable — a full-strength blur plus 55% black
        // (what this used while the panel was a centered card taking over the
        // whole screen) removed the surroundings entirely, which no longer
        // suits a band that is visibly attached to one icon among them.
        let tint = NSView(frame: backdrop.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor.black.withAlphaComponent(0.42).cgColor
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
        let placement = Self.bandPlacement(
            size: size,
            in: backdropSize,
            anchorIconFrame: metrics.anchorIconFrame
        )
        panel.frame = placement.frame
        if placement.showsNotch, let anchor = metrics.anchorIconFrame {
            let notch = FolderBandNotchView(
                frame: NSRect(
                    x: min(max(anchor.midX - Self.notchWidth / 2, panel.frame.minX + 20),
                           panel.frame.maxX - Self.notchWidth - 20),
                    y: panel.frame.maxY,
                    width: Self.notchWidth,
                    height: Self.notchHeight
                )
            )
            backdrop.addSubview(notch)
            bandNotch = notch
        }
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

    /// Where the band sits, and whether the notch is meaningful there.
    ///
    /// The band grows out of the folder icon the way the system's own does —
    /// but only when it actually fits below it. This grid's icons can be large
    /// enough that a three-row folder is most of the screen tall, and forcing
    /// such a band under its icon just pins it to the top of the screen with
    /// the icon buried somewhere inside it. A notch pointing at something the
    /// band is itself covering is worse than no notch, so when the band cannot
    /// sit below its icon it centers instead and drops the notch.
    ///
    /// Pure so the placement can be checked without a window. AppKit's y axis
    /// runs upward here, so "below the icon" means a *smaller* maxY.
    struct BandPlacement: Equatable {
        let frame: NSRect
        let showsNotch: Bool
    }

    static func bandPlacement(size: NSSize, in hostSize: NSSize, anchorIconFrame: NSRect?) -> BandPlacement {
        let x = (hostSize.width - size.width) / 2
        let centered = NSRect(
            x: x,
            y: (hostSize.height - size.height) / 2,
            width: size.width,
            height: size.height
        )
        guard let anchor = anchorIconFrame else {
            return BandPlacement(frame: centered, showsNotch: false)
        }
        let below = anchor.minY - Self.notchHeight - size.height
        let fitsBelow = below >= Self.bandScreenMargin
        guard fitsBelow else { return BandPlacement(frame: centered, showsNotch: false) }
        return BandPlacement(
            frame: NSRect(x: x, y: below, width: size.width, height: size.height),
            showsNotch: true
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
                self?.bandNotch = nil
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
/// The small upward triangle joining the band to the folder icon above it —
/// the visual claim that the panel came out of that icon rather than appearing
/// from nowhere. Decorative only, so it never takes a click — a purely
/// decorative view that swallows clicks is a bug this codebase has shipped
/// before.
private final class FolderBandNotchView: NSView {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        let path = NSBezierPath()
        path.move(to: NSPoint(x: bounds.minX, y: bounds.minY))
        path.line(to: NSPoint(x: bounds.midX, y: bounds.maxY))
        path.line(to: NSPoint(x: bounds.maxX, y: bounds.minY))
        path.close()
        // Matches the band's own glass tint rather than a flat fill, so the two
        // read as one surface.
        NSColor.white.withAlphaComponent(0.09).setFill()
        path.fill()
    }
}

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
