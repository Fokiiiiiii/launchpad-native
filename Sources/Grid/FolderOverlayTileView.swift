import AppKit
import Localization
import SwiftUI
import UniformTypeIdentifiers

/// One app tile inside an opened folder's grid — adapted directly from the
/// user-supplied design reference's `AppTile` (icon branch) and
/// `TileButtonStyle`: same squircle corner ratio (`icon * 0.236`), same
/// top-light gradient overlay + hairline stroke, same hover lift
/// (`offset(y: -2)`) and press scale (`0.90`) driven by the reference's own
/// `TSAnimation.snappy` spring (`response: 0.26, dampingFraction: 0.90`),
/// same label font/gap/shadow — real app icons via `Image(nsImage:)` in
/// place of the reference's placeholder gradient+monogram tile.
struct FolderOverlayTile: Identifiable {
    let id: String
    let name: String
    var icon: NSImage?
    let onLaunch: () -> Void
    let onOpenNewInstance: (() -> Void)?
    let onShowInFinder: () -> Void
    let onRemoveFromFolder: () -> Void
    /// Real, confirmed report ("フォルダ内のアプリ移動が違和感がある"):
    /// the previous single `onReorder` fired only on drop, with no live
    /// feedback while dragging — unlike the main grid's `ItemDragSession`,
    /// where other icons visibly shift out of the way in real time as the
    /// dragged icon hovers near them. These three replace it, matching that
    /// same split: `onDragStart` fires the instant a drag begins (set
    /// synchronously inside the source tile's own `.onDrag` closure — see
    /// `FolderOverlayGridModel.draggingID`'s doc comment for why that
    /// timing matters), `onDragHoverEntered` fires every time the drag
    /// enters a *different* tile's drop region (drives the live reorder
    /// preview), and `onDropCommit` fires once, when a drop actually lands,
    /// to persist whatever order the live preview has already settled on.
    let onDragStart: () -> Void
    let onDragHoverEntered: () -> Void
    let onDropCommit: () -> Bool
}

private struct TileReorderDropDelegate: DropDelegate {
    let onHoverEntered: () -> Void
    let onCommit: () -> Bool
    func dropEntered(info: DropInfo) { onHoverEntered() }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { onCommit() }
}

/// Wraps the whole tile grid (not any one tile) purely to catch `dropExited`
/// when a drag leaves the reorderable area entirely without landing on any
/// tile — the coarse "this drag is going nowhere" signal `DropDelegate`
/// otherwise has no way to express, since neither `performDrop` nor any
/// per-tile callback fires in that case. `FolderContentsViewController`'s
/// own global-mouseUp safety net (mirroring the main grid's
/// `itemDragGlobalMouseUpMonitor`) covers the residual gap this still
/// doesn't — Escape, or the drag ending while still hovering *inside* the
/// grid but over empty space rather than a tile.
private struct FolderGridOuterDropDelegate: DropDelegate {
    let onDragCancelled: () -> Void
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func performDrop(info: DropInfo) -> Bool { onDragCancelled(); return false }
    func dropExited(info: DropInfo) { onDragCancelled() }
}

/// Real, confirmed report ("フォルダ内だとアプリの並び替えができない"):
/// the tile used to derive its press-scale feedback from a hand-rolled
/// `.simultaneousGesture(DragGesture(minimumDistance: 0))` that set a
/// `@State` flag on `.onChanged`. `minimumDistance: 0` means that gesture
/// claims the touch the instant `mouseDown` happens — on macOS specifically,
/// competing with `.onDrag`'s own drag-session initiation (which itself
/// needs to observe the *first* bit of pointer movement to decide "this is
/// a drag, not a click") for the same touch. `ButtonStyle.isPressed` is the
/// idiomatic way to get identical press feedback without adding any gesture
/// of the tile's own at all — no competition, because there's nothing left
/// to compete with.
private let tileSnappy = Animation.spring(response: 0.26, dampingFraction: 0.90)

private struct TileButtonStyle: ButtonStyle {
    let hovering: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.90 : 1)
            .offset(y: hovering ? -2 : 0)
            .animation(tileSnappy, value: configuration.isPressed)
            .animation(tileSnappy, value: hovering)
    }
}

struct FolderOverlayTileView: View {
    let tile: FolderOverlayTile
    let iconSize: CGFloat
    /// Whether *this* tile is the one currently being dragged — passed down
    /// from `FolderOverlayGridContent`'s `ForEach` (`tile.id ==
    /// model.draggingID`) rather than observed here directly, matching this
    /// view's existing "don't subscribe to more than you need" shape
    /// (`hovering` is likewise purely local `@State`).
    let isDragging: Bool

    @State private var hovering = false

    private var corner: CGFloat { iconSize * 0.236 }

    var body: some View {
        Button(action: tile.onLaunch) {
            VStack(spacing: 9) {
                icon
                Text(tile.name)
                    .font(.system(size: 12.5))
                    .foregroundStyle(.white.opacity(0.94))
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .shadow(color: .black.opacity(0.6), radius: 3, y: 1)
                    .frame(maxWidth: iconSize + 56)
            }
            .padding(.top, 6)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
        // Real, confirmed report ("フォルダ内のアプリ移動が違和感がある"):
        // `.onDrag` already gives the dragged tile a translucent floating
        // snapshot that follows the cursor for free (the SwiftUI analogue
        // of the main grid's own `floatingView`) — what was missing is the
        // *source* cell's own half of that lift: dimming/shrinking in place
        // while its floating copy is what the user actually tracks. No new
        // gesture is added here (still just `.opacity`/`.scaleEffect`
        // driven by existing/new @Published state) — the earlier
        // `.simultaneousGesture(DragGesture(minimumDistance: 0))` that once
        // broke `.onDrag`'s own recognition is not reintroduced.
        .opacity(isDragging ? 0.35 : 1)
        .scaleEffect(isDragging ? 0.92 : 1)
        .animation(tileSnappy, value: isDragging)
        // `NSString` conforms to `NSItemProviderWriting`/`-Reading` out of
        // the box — the payload is just this tile's own `id`, which
        // `FolderContentsViewController`'s drag callbacks use to look up
        // both the dragged and hovered/dropped-on items' current positions.
        .onDrag {
            tile.onDragStart()
            return NSItemProvider(object: tile.id as NSString)
        }
        .onDrop(of: [.text], delegate: TileReorderDropDelegate(onHoverEntered: tile.onDragHoverEntered, onCommit: tile.onDropCommit))
        .contextMenu {
            Button { tile.onLaunch() } label: { Label(L10n.menuOpen, systemImage: "arrow.up.forward.app") }
            if let onOpenNewInstance = tile.onOpenNewInstance {
                Button { onOpenNewInstance() } label: { Label(L10n.menuOpenNewInstance, systemImage: "macwindow.badge.plus") }
            }
            Button { tile.onShowInFinder() } label: { Label(L10n.menuShowInFinder, systemImage: "folder") }
            Divider()
            Button { tile.onRemoveFromFolder() } label: { Label(L10n.menuRemoveFromFolder, systemImage: "folder.badge.minus") }
        }
    }

    @ViewBuilder
    private var icon: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        ZStack {
            if let nsImage = tile.icon {
                Image(nsImage: nsImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Color.white.opacity(0.08)
            }
        }
        .frame(width: iconSize, height: iconSize)
        .clipShape(shape)
        // Real, confirmed report ("変な枠がある", reproduced against the
        // real "ゲーム" folder — 5 items, matching the reported
        // screenshot's 5 tiles exactly): this hairline stroke used to
        // outline every tile's icon uniformly regardless of the icon's own
        // artwork or color, which is exactly what made it read as an
        // applied "frame" rather than part of any one icon. Matches the
        // same "this codebase's own icon chrome reads as unwanted
        // decoration against its dark theme" lesson as the shadow removed
        // just below — the main grid's `GridCellItem.swift` draws no
        // border around its icons either.
        // Real, confirmed report ("アプリの黒背景", reproduced with the
        // real DictionaryTool/ConfigDialog icons rendered through the
        // actual `FolderContentsViewController` against this panel's real
        // dark backdrop — see the temp probe this fix was verified with):
        // the previous pass correctly clipped `.shadow()` to the icon's
        // real composited alpha shape via `compositingGroup()`, but even a
        // *correctly shaped* shadow of a mostly-opaque rounded-square icon
        // is itself a visibly darker rounded square — against this app's
        // dark folder backdrop (not a light one), that reads exactly like
        // a black frame, regardless of how tightly it hugs the icon. This
        // codebase already hit and resolved the identical complaint twice
        // before by removing the shadow outright rather than reshaping it:
        // the closed-folder mosaic `FolderIconView.swift` has no shadow at
        // all (see its own doc comment, commit 5247ea1), and the main
        // grid's AppKit tiles (`GridCellItem.swift`) never apply one
        // either. Matches that established, dark-theme-appropriate
        // precedent here too.
        .compositingGroup()
    }
}

/// Backing store for `FolderOverlayGridContent` — a plain `ObservableObject`
/// so `FolderContentsViewController` (an `NSViewController`, not a SwiftUI
/// view) can push tile updates into the hosted SwiftUI tree without either
/// side needing to know about the other's framework.
final class FolderOverlayGridModel: ObservableObject {
    @Published var tiles: [FolderOverlayTile] = []
    /// id of the tile currently mid-drag, or `nil` between drags. Set
    /// synchronously inside the source tile's own `.onDrag` closure —
    /// SwiftUI calls that closure on the main thread the instant a drag
    /// begins, before any `DropDelegate` callback on any tile can possibly
    /// fire, so every hover/drop callback below can just read this directly
    /// instead of round-tripping the dragged `NSItemProvider`'s payload
    /// asynchronously on every hover frame.
    @Published var draggingID: String?
}

/// Adapted directly from the design reference's `FolderOverlay`'s inner
/// grid (`LazyVGrid(columns: Array(repeating: .flexible(), count:
/// metrics.columns), spacing: 26)` + the same horizontal/vertical padding)
/// — always exactly `columns` columns regardless of item count, matching
/// the main grid's own column count, with only the row count varying. The
/// dimming backdrop and glass card itself are the caller's concern
/// (`GridViewController.FolderOverlayBackdropView` / `GlassBackgroundHelper`
/// respectively) — this view is only the tile grid.
struct FolderOverlayGridContent: View {
    @ObservedObject var model: FolderOverlayGridModel
    let columns: Int
    let iconSize: CGFloat
    /// Fires when a drag leaves the grid without landing on any tile — see
    /// `FolderGridOuterDropDelegate`'s own doc comment for why this exists
    /// alongside (not instead of) the controller's global-mouseUp safety
    /// net.
    let onDragCancelled: () -> Void

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: max(columns, 1)),
            spacing: 26
        ) {
            ForEach(model.tiles) { tile in
                FolderOverlayTileView(tile: tile, iconSize: iconSize, isDragging: tile.id == model.draggingID)
            }
        }
        // Sized to its columns and centered, rather than stretched: the band
        // spans the screen, but a folder holding three apps must not spread
        // them across all of it.
        .frame(width: CGFloat(max(columns, 1)) * (iconSize + 56))
        .padding(.vertical, 34)
        .frame(maxWidth: .infinity)
        .onDrop(of: [.text], delegate: FolderGridOuterDropDelegate(onDragCancelled: onDragCancelled))
    }
}
