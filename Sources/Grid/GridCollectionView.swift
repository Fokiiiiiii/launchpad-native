import AppKit
import Diagnostics

final class GridCollectionView: NSCollectionView {
    var menuProvider: ((IndexPath) -> NSMenu?)?
    /// Fires with `-1` (previous) or `+1` (next) for a *discrete* mouse-wheel
    /// page change (see the discrete-wheel branch in `scrollWheel` below) —
    /// that hardware has no continuous position data, so there's nothing to
    /// drive a finger-tracked drag with; it just jumps.
    var onSwipePage: ((Int) -> Void)? {
        didSet { swipeRecognizer.callbacks.onDiscretePage = onSwipePage }
    }
    /// Trackpad 2-finger horizontal swipe, tracked continuously once
    /// engaged (past `minimumEngageDistance`). `onSwipeChanged` fires with
    /// the *cumulative* delta since the gesture began (not a per-frame
    /// delta), so callers can drive an overlay's transform 1:1 with the
    /// fingers. `onSwipeEnded` additionally passes a simple velocity
    /// estimate (points per second, from the last few samples) for
    /// apple-design-style velocity handoff into a settle animation.
    var onSwipeBegan: (() -> Void)? {
        didSet { swipeRecognizer.callbacks.onBegan = onSwipeBegan }
    }
    var onSwipeChanged: ((CGFloat) -> Void)? {
        didSet { swipeRecognizer.callbacks.onChanged = onSwipeChanged }
    }
    var onSwipeEnded: ((CGFloat, CGFloat) -> Void)? {
        didSet { swipeRecognizer.callbacks.onEnded = onSwipeEnded }
    }
    /// Fires when a click lands within a cell's bounding box but outside its
    /// actual icon+label content — see `GridCellItem.contentHitTestFrame`.
    /// Treated the same as clicking the launcher's empty background: dismiss.
    var onBackgroundClick: (() -> Void)?

    /// The gesture itself lives in `SwipePageRecognizer` so an opened folder
    /// can page by the same one. A page fits entirely in the viewport, so this
    /// view has nothing of its own to scroll — the override exists purely to
    /// feed the recognizer.
    private let swipeRecognizer = SwipePageRecognizer()

    var scrollsVertically = false

    override func scrollWheel(with event: NSEvent) {
        if scrollsVertically {
            if let scroll = enclosingScrollView { scroll.scrollWheel(with: event) }
            else { super.scrollWheel(with: event) }
        } else {
            swipeRecognizer.handle(event)
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        if !selectionIndexPaths.contains(indexPath) {
            selectionIndexPaths = [indexPath]
        }
        return menuProvider?(indexPath)
    }

    /// Fires on mouseDown when the click lands within a cell's real content
    /// area (not its full, often-larger bounding box). `GridViewController`
    /// drives its own press/lift/reorder/folder-candidate/page-turn state
    /// machine from here — see that type's "Item drag" section — rather
    /// than letting NSCollectionView's built-in selection+drag machinery
    /// handle it, since that machinery has no notion of live neighbor
    /// displacement, folder-candidate hover zones, or drag-triggered page
    /// turning (the user's explicit "iOS home screen" interaction ask).
    var onItemMouseDown: ((IndexPath, NSEvent) -> Void)?
    var onItemMouseDragged: ((NSEvent) -> Void)?
    var onItemMouseUp: ((NSEvent) -> Void)?

    var onMarqueeBegin: ((Bool) -> Void)?
    var onMarqueeChange: ((NSRect) -> Void)?
    var onMarqueeEnd: (() -> Void)?
    private var backgroundPress: NSPoint?
    private var backgroundAdditive = false
    private var marqueeActive = false
    private var marqueeView: NSView?

    private var itemPressActive = false

    var isMarqueeActive: Bool { marqueeActive }

    var onMarqueePointer: ((NSPoint) -> Void)?

    private var marqueeGeneration: UInt = 0
    private var marqueeMonitor: MarqueeMonitor?

    deinit { marqueeMonitor?.remove() }

    func cancelMarquee() {
        let wasActive = marqueeActive
        marqueeGeneration &+= 1
        marqueeMonitor?.remove()
        marqueeMonitor = nil
        itemPressActive = false
        backgroundPress = nil
        marqueeActive = false
        marqueeView?.removeFromSuperview()
        marqueeView = nil
        if wasActive { onMarqueeEnd?() }
    }

    override func mouseDown(with event: NSEvent) {
        cancelMarquee()
        let point = convert(event.locationInWindow, from: nil)
        if let indexPath = indexPathForItem(at: point),
           let cell = item(at: indexPath) as? GridCellItem {
            let localPoint = cell.view.convert(point, from: self)
            if cell.contentHitTestFrame.insetBy(dx: -10, dy: -10).contains(localPoint) {
                DiagnosticsLog.grid.notice("GridCollectionView.mouseDown: content hit at \(indexPath.item, privacy: .public)")
                itemPressActive = true
                onItemMouseDown?(indexPath, event)
                return
            }
        }
        DiagnosticsLog.grid.notice("GridCollectionView.mouseDown: background click at \(String(describing: point), privacy: .public)")
        backgroundPress = point
        backgroundAdditive = event.modifierFlags.contains(.command)
    }

    /// AppKit keeps routing mouseDragged/mouseUp to whichever view received
    /// the initiating mouseDown, for the duration of that press — standard
    /// NSResponder tracking behavior, no extra setup needed here.
    override func mouseDragged(with event: NSEvent) {
        DiagnosticsLog.grid.debug("GridCollectionView.mouseDragged fired")
        guard let start = backgroundPress else {
            if itemPressActive { onItemMouseDragged?(event) }
            return
        }
        let end = convert(event.locationInWindow, from: nil)
        if !marqueeActive {
            guard hypot(end.x - start.x, end.y - start.y) >= 4 else { return }
            marqueeActive = true
            onMarqueeBegin?(backgroundAdditive)
            guard marqueeActive else { return }
            armMarqueeSafety()
            let overlay = NSView()
            overlay.wantsLayer = true
            overlay.layer?.backgroundColor = NSColor.controlAccentColor.withAlphaComponent(0.15).cgColor
            overlay.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.8).cgColor
            overlay.layer?.borderWidth = 1
            overlay.setAccessibilityElement(false)
            addSubview(overlay)
            marqueeView = overlay
        }
        let rect = NSRect(x: min(start.x, end.x), y: min(start.y, end.y), width: abs(end.x - start.x), height: abs(end.y - start.y))
        marqueeView?.frame = rect
        onMarqueeChange?(rect)
        onMarqueePointer?(end)
    }

    private func armMarqueeSafety() {
        marqueeGeneration &+= 1
        let generation = marqueeGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + ItemDrag.itemDragSafetyNetTimeout) { [weak self] in
            Task { @MainActor in
                guard let self, self.marqueeActive, self.marqueeGeneration == generation else { return }
                self.cancelMarquee()
            }
        }
        guard window != nil else { return }
        if let token = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseUp], handler: { [weak self] _ in
            Task { @MainActor in
                guard let self, self.marqueeActive, self.marqueeGeneration == generation else { return }
                self.cancelMarquee()
            }
        }) { marqueeMonitor = MarqueeMonitor(token) }
    }

    override func mouseUp(with event: NSEvent) {
        DiagnosticsLog.grid.debug("GridCollectionView.mouseUp fired")
        guard backgroundPress != nil else {
            guard itemPressActive else { return }
            itemPressActive = false
            onItemMouseUp?(event)
            return
        }
        let wasActive = marqueeActive
        cancelMarquee()
        if !wasActive { onBackgroundClick?() }
    }


}

private final class MarqueeMonitor: @unchecked Sendable {
    private let token: Any
    init(_ token: Any) { self.token = token }
    func remove() { NSEvent.removeMonitor(token) }
}
