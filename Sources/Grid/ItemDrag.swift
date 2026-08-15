import AppKit
import Persistence

/// State and tuning for one in-progress item drag.
///
/// Split out of `GridViewController` so the drag's own vocabulary — what a
/// session holds, and the timing/geometry constants that govern it — reads as
/// one unit instead of being interleaved with the controller's view wiring.
/// Behaviour is unchanged; every value here is the one the drag already used.
///
/// The constants are deliberately named and documented rather than inlined:
/// each encodes a decision made against real hardware, and several were
/// changed in response to specific reports.
@MainActor
enum ItemDrag {
    /// Which slot the dragged item occupies on `page`, or `nil` if it is not
    /// on that page at all.
    ///
    /// A drag can carry the pointer across page turns while the item itself
    /// stays on the page it was picked up from. Everything that reasons about
    /// the page currently in view — which cell to leave out of the reorder
    /// preview, which cells may become folder targets, how many slots a drop
    /// can choose between — needs this rather than the item's origin index.
    ///
    /// Both directions matter. Reported bug ("次のページまで持っていって
    /// 戻すと元の位置に同じアプリが出てきて増殖する"): returning to the
    /// origin page must restore the exclusion, or the item's own cell is laid
    /// out and drawn again beneath the floating icon still under the cursor.
    nonisolated static func sourceIndex(
        onPage page: Int,
        sourcePage: Int,
        sourceOriginalIndex: Int
    ) -> Int? {
        page == sourcePage ? sourceOriginalIndex : nil
    }

    /// `@unchecked Sendable`: `Timer.scheduledTimer`'s completion closure is
    /// technically a non-isolated context by Swift 6's rules, but in
    /// practice it always fires on the main run loop (the same actor this
    /// entire view controller is isolated to) — there is no real
    /// cross-thread access here, just the compiler unable to see that a
    /// `Timer` scheduled from `@MainActor` code stays on that same thread.
    final class ItemDragSession: @unchecked Sendable {
        let sourcePage: Int
        let sourceOriginalIndex: Int
        let draggedItem: LayoutItem
        let originalFrame: NSRect
        /// The floating view's frame, in the top-level host coordinates, set exactly
        /// once at creation and never reassigned — see `updateItemDrag`'s
        /// doc comment for why: all *movement* after that happens purely
        /// via `transform.translation.x/y`, matching every other continuous
        /// drag in this codebase (page-drag, reorder preview). Needed here
        /// as the fixed baseline those translation deltas are computed from.
        var floatingViewOriginalFrameInHost: NSRect = .zero
        /// Offset from the cell's origin to where the user actually grabbed
        /// it — respected while following the cursor so the icon doesn't
        /// jump to be centered under the pointer (apple-design's direct-
        /// manipulation guidance).
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
        var edgePeekImageView: NSImageView?
        /// Last offset/timestamp applied to the peek — reused by §8c to
        /// approximate a release velocity when the page-turn commit spring
        /// re-targets a peek that's still easing.
        var lastPeekOffset: CGFloat?
        var lastPeekTime: CFTimeInterval?
        /// Real, confirmed report ("グループ化しようとするとアプリが逃げる
        /// ...わかりやすくできない？"): a standalone overlay (same pattern
        /// as `floatingView`/`edgePeekImageView` — never a sublayer added to
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
    /// Real, confirmed report ("フォルダ判定をもう少し遅く"): 0.5s let a
    /// brief pass-over during reordering register as folder intent too
    /// easily. Raised to 0.7s — still well under a full second (doesn't
    /// read as unresponsive) but requires more deliberate dwell before
    /// committing. The hover-progress ring's own sweep duration and the
    /// debug-hook wait both read this constant directly, so both track the
    /// new value automatically.
    static let itemDragFolderHoverDelay: TimeInterval = 0.7
    /// iOS's own folder-creation highlight reads as "a little more than the
    /// icon," not a separate shape — noticeably but not dramatically larger
    /// than the icon it wraps. 1.18x keeps the padding visible without the
    /// indicator ballooning into neighboring cells at tight column counts.
    static let itemDragFolderZoneIndicatorScale: CGFloat = 1.18
    /// Deliberately rounder than `GridCellItem`'s own app-icon squircle
    /// ratio (0.236, `applyIconSize`) — this is a plain rounded-square
    /// backdrop, not an icon mask, and a plumper curve reads as
    /// "background" rather than "blank icon."
    static let itemDragFolderZoneIndicatorCornerRatio: CGFloat = 0.28
    /// Real, confirmed report ("上からやってもなんの反応もない"): now that
    /// the 2D hysteresis radius below is the sole anti-chatter gate (see its
    /// doc comment), this additional time delay only added pure lag on top
    /// — dropped to 0. The `Timer` mechanism itself is unchanged so a future
    /// tuning pass can reintroduce a nonzero value without restructuring
    /// anything.
    static let itemDragReorderDebounce: TimeInterval = 0.0
    static let itemDragFolderZoneInset: CGFloat = 0.2 // ~60% center region
    /// Round 12 §8a: the pointer must move this fraction of a cell's own
    /// short side past the committed slot's center before the candidate slot
    /// is allowed to change at all — a real hysteresis band (spec 7.3)
    /// around the current selection, replacing the old "any raw nearest-slot
    /// change restarts the debounce timer" behavior, which could still
    /// flicker if the pointer sat right on a cell boundary. Real, confirmed
    /// report ("狙った位置にアプリを置いてもそこにあるアプリが動かない"):
    /// judging this from `point.x` alone made straight vertical drags onto
    /// a different row never satisfy the crossing condition — this is now a
    /// straight-line distance from the committed cell's center, so movement
    /// in any direction (including pure vertical) can cross it. Raised
    /// slightly from 0.15 to 0.18 alongside dropping the debounce above to
    /// 0 — with hysteresis now the *only* anti-chatter layer (instead of
    /// splitting the job with a time delay), a touch more radius keeps
    /// boundary flicker damped without feeling sluggish.
    static let itemDragHysteresisFraction: CGFloat = 0.18
    /// Real, confirmed report ("ページ端についてその先へ無理や進もうとし
    /// た時に起きるアニメーションが過剰すぎる"): the old linear
    /// `proximity * 30` formula meant the preview kept growing the harder
    /// the pointer pushed toward the edge, with no natural ceiling short of
    /// the zone's own zero/one clamp. `updateEdgePeek` now runs the
    /// penetration distance through the existing `rubberBand` helper
    /// (already used for the trackpad page-swipe's own edge resistance)
    /// instead — overshoot-proportional resistance rather than a hard
    /// linear ramp. This constant is the rubber band's `dimension`
    /// term (how quickly it saturates), not a maximum offset: measured
    /// output for `itemDragEdgeZoneWidth`(70)-sized penetration is ≈14.8pt,
    /// and ≈5.8pt at 14pt of penetration — both comfortably below the old
    /// linear formula's up-to-30pt sweep.
    static let itemDragEdgePeekResistanceDimension: CGFloat = 24
    /// Real, confirmed bug found via a genuine (not simulated) trackpad
    /// drag on this exact codebase: `mouseDown` -> `mouseDragged` ->
    /// `beginItemDrag` all fired correctly, but `mouseUp` never arrived —
    /// AppKit's per-window mouse-tracking continuity (the mechanism
    /// `GridCollectionView`'s override relies on) isn't guaranteed if the
    /// pointer leaves the window's bounds, key status changes, or a handful
    /// of other real-world edge cases a synthetic in-bounds test never hits.
    /// Without a way out, `activeItemDrag` stayed non-nil forever — the
    /// floating icon stuck on screen, and every subsequent
    /// `handleItemMouseDown` treating the grid as still mid-drag,
    /// effectively freezing all grid interaction ("操作が効かない"). Two
    /// independent nets, matching the page-drag machinery's own established
    /// pattern:
    ///  1. A fixed, generous fallback timer (far longer than any real
    ///     drag) that force-reverts no matter what.
    ///  2. A *global* mouse-up monitor — catches a real mouseUp AppKit
    ///     delivered somewhere else entirely (a different view/window)
    ///     instead of back to `GridCollectionView`, which the per-window
    ///     tracking continuity alone can miss.
    static let itemDragSafetyNetTimeout: TimeInterval = 15.0
}
