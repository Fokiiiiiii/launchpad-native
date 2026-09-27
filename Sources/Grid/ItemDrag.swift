import AppKit
import Persistence

/// State and tuning for one in-progress item drag.
///
/// The constants are named rather than inlined because each encodes a decision
/// made against real hardware, several in response to specific reports.
@MainActor
enum ItemDrag {
    /// Which slot the dragged item occupies on `page`, or `nil` if it is not on
    /// that page — a drag can cross page turns while the item stays behind.
    ///
    /// Both directions matter: returning to the origin page must restore the
    /// exclusion, or the item is drawn again beneath the floating icon
    /// ("次のページまで持っていって戻すと…アイコンが増殖する").
    nonisolated static func sourceIndex(
        onPage page: Int,
        sourcePage: Int,
        sourceOriginalIndex: Int
    ) -> Int? {
        page == sourcePage ? sourceOriginalIndex : nil
    }

    /// `@unchecked Sendable`: a `Timer` closure is non-isolated by Swift 6's
    /// rules but always fires on the main run loop, which is the actor this is
    /// already confined to.
    final class ItemDragSession: @unchecked Sendable {
        let sourcePage: Int
        let sourceOriginalIndex: Int
        let draggedItem: LayoutItem
        let originalFrame: NSRect
        /// Set once at creation and never reassigned: movement happens purely
        /// through `transform.translation`, and this is the baseline those
        /// deltas are measured from. See `updateItemDrag` for why.
        var floatingViewOriginalFrameInHost: NSRect = .zero
        /// Where the user grabbed the cell, so the icon does not jump to centre
        /// itself under the pointer.
        let grabOffset: NSPoint
        var floatingView: NSView?
        weak var floatingViewHost: NSView?
        var candidateSlot: Int
        var pendingRawSlot: Int
        var folderCandidateOriginalIndex: Int?
        var pendingRawFolderCandidateIndex: Int?
        var edgeDirection: Int = 0
        /// Last raw drag point (collectionView-local), refreshed on every
        /// `updateItemDrag` call — reused by `commitPageTurnDuringDrag` to
        /// re-evaluate candidates on the new page without needing to derive
        /// a point back out of the floating view's (now `.frame`-immutable)
        /// position.
        var lastPoint: NSPoint = .zero
        var reorderTimer: Timer?
        var folderTimer: Timer?
        var edgeTimer: Timer?
        /// Round 12 §8b: the incoming-page preview shown while the pointer
        /// dwells in the edge zone, before the dwell timer actually commits
        /// a page turn. `nil` whenever the pointer isn't currently in an
        /// edge zone.
        var edgePeekView: NSView?
        /// Last offset/timestamp applied to the peek — reused by §8c to
        /// approximate a release velocity when the page-turn commit spring
        /// re-targets a peek that's still easing.
        var lastPeekOffset: CGFloat?
        var lastPeekTime: CFTimeInterval?
        /// True from the moment a mid-drag page turn slides the collection
        /// view a full page's width until its settle block puts it back.
        ///
        /// The turn is the one place that moves the collection view itself
        /// rather than a peek view, and the only thing that undoes it is
        /// `commitPageChange` — inside a block guarded on the drag still being
        /// live. Letting go inside that window makes the guard bail, so the
        /// drag's own teardown has to finish the job; this is what tells it
        /// there is a turn to finish.
        var pageTurnInFlight = false
        /// Real, confirmed report ("グループ化しようとするとアプリが逃げる
        /// ...わかりやすくできない？"): a standalone overlay (same pattern
        /// as `floatingView`/`edgePeekView` — never a sublayer added to
        /// a reusable `GridCellItem`, since `prepareForReuse` only resets
        /// that cell's own transform/opacity/animations, not arbitrary
        /// sublayers someone else added) that shows the folder drop zone's
        /// bounds and a hover-progress sweep. `nil` whenever the pointer
        /// isn't currently over another app's center zone.
        var folderZoneIndicatorView: NSView?
        /// Where the dragged item currently sits *on the page being shown*, or
        /// `nil` once a mid-drag page turn has carried the drag onto a page the
        /// item isn't part of.
        ///
        /// `sourceOriginalIndex` is a `let` describing the item's index on its
        /// **origin** page, which is what `endItemDrag` needs for the model
        /// mutation. Everything that reasons about the *currently displayed*
        /// page — which cell to exclude from the reorder preview, which cells
        /// can be folder targets, how many slots exist — was reading that same
        /// value, so after `commitPageTurnDuringDrag` it pointed at an
        /// unrelated app on the new page: the preview excluded the wrong cell
        /// (shifting every following slot by one), that app could not be made
        /// into a folder, and the slot count was short by one so the item could
        /// not be dropped at the end. `commitPageTurnDuringDrag` already resets
        /// `pendingRawSlot`/`candidateSlot`/`edgeDirection`/folder-candidate
        /// state for the new page for exactly this class of reason; this is the
        /// remaining piece of that same reset.
        var sourceIndexOnCurrentPage: Int?
        let generation: Int

        init(sourcePage: Int, sourceOriginalIndex: Int, draggedItem: LayoutItem, originalFrame: NSRect, grabOffset: NSPoint, generation: Int) {
            self.sourcePage = sourcePage
            self.sourceOriginalIndex = sourceOriginalIndex
            self.draggedItem = draggedItem
            self.originalFrame = originalFrame
            self.grabOffset = grabOffset
            self.candidateSlot = sourceOriginalIndex
            self.pendingRawSlot = sourceOriginalIndex
            self.sourceIndexOnCurrentPage = sourceOriginalIndex
            self.generation = generation
        }

        func invalidateTimers() {
            reorderTimer?.invalidate()
            folderTimer?.invalidate()
            edgeTimer?.invalidate()
        }
    }

    static let itemDragThresholdDistance: CGFloat = 6
    static let itemDragEdgeZoneWidth: CGFloat = 70
    static let itemDragEdgeHoverDelay: TimeInterval = 0.45
    /// Raised from 0.5s ("フォルダ判定をもう少し遅く"): a brief pass-over while
    /// reordering registered as folder intent too easily.
    static let itemDragFolderHoverDelay: TimeInterval = 0.7
    /// Reads as "a little more than the icon", not a separate shape — larger
    /// scales spill into neighbouring cells at tight column counts.
    static let itemDragFolderZoneIndicatorScale: CGFloat = 1.18
    /// Rounder than the icon squircle (0.236) on purpose: a plumper curve reads
    /// as a backdrop rather than a blank icon.
    static let itemDragFolderZoneIndicatorCornerRatio: CGFloat = 0.28
    /// 0 since the 2D hysteresis below became the sole anti-chatter gate; a
    /// time delay on top was pure lag ("上からやってもなんの反応もない"). The
    /// timer remains so a nonzero value can be reintroduced.
    static let itemDragReorderDebounce: TimeInterval = 0.0
    static let itemDragFolderZoneInset: CGFloat = 0.2 // ~60% center region
    /// Fraction of a cell's short side the pointer must clear, measured as a
    /// straight-line distance from the committed cell's centre. Judging it on
    /// `point.x` alone meant a purely vertical drag never crossed
    /// ("狙った位置にアプリを置いてもそこにあるアプリが動かない").
    static let itemDragHysteresisFraction: CGFloat = 0.18
    /// The rubber band's `dimension` term (how fast it saturates), not a
    /// maximum offset: 70pt of penetration yields ≈14.8pt, 14pt yields ≈5.8pt.
    /// Replaced a linear ramp that grew without ceiling
    /// ("ページ端…アニメーションが過剰すぎる"). Pinned by `GridSpringTests`.
    static let itemDragEdgePeekResistanceDimension: CGFloat = 24
    /// Backstop for a real drag where `mouseUp` never arrived: AppKit's
    /// per-window tracking continuity is not guaranteed once the pointer leaves
    /// the window or key status changes. Without an exit `activeItemDrag` stayed
    /// non-nil forever and froze all grid interaction ("操作が効かない"). Paired
    /// with a global mouse-up monitor, which catches an up delivered elsewhere.
    static let itemDragSafetyNetTimeout: TimeInterval = 15.0
}
