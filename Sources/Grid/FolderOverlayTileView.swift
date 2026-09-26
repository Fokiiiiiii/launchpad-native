import AppKit
import Localization
import SwiftUI
import UniformTypeIdentifiers

struct FolderOverlayTile: Identifiable {
    let id: String
    let name: String
    var icon: NSImage?
    let onLaunch: () -> Void
    let onOpenNewInstance: (() -> Void)?
    let onShowInFinder: () -> Void
    let onRename: () -> Void
    let onHide: () -> Void
    let onRemoveFromFolder: () -> Void
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
    /// Whether the keyboard selection is on this tile. Drawn as a filled
    /// rounded plate behind the icon and label, the same idea as the grid's
    /// own selection tile.
    let isSelected: Bool

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
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(.white.opacity(isSelected ? 0.16 : 0))
                    .padding(.horizontal, -8)
                    .padding(.vertical, -4)
            )
            .animation(tileSnappy, value: isSelected)
            .contentShape(Rectangle())
        }
        .buttonStyle(TileButtonStyle(hovering: hovering))
        .onHover { hovering = $0 }
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
            // Same items, same order as the grid's menu. Leaving rename and
            // hide out meant an app kept in a folder could only be renamed or
            // hidden by finding it through search or dragging it back out.
            Button { tile.onRename() } label: { Label(L10n.menuRename, systemImage: "pencil") }
            Button { tile.onHide() } label: { Label(L10n.menuHide, systemImage: "eye.slash") }
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
    /// id of the tile the keyboard is on, or `nil` while the panel has no
    /// keyboard selection. Separate from `draggingID` because the two can
    /// legitimately point at different tiles.
    @Published var selectedID: String?
}

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
                FolderOverlayTileView(
                    tile: tile,
                    iconSize: iconSize,
                    isDragging: tile.id == model.draggingID,
                    isSelected: tile.id == model.selectedID
                )
            }
        }
        // Left-aligned, not centered: the panel is a fixed width, so a folder
        // holding two apps starts them at the same place a full one does
        // instead of floating them in the middle of an otherwise empty row.
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 22)
        .padding(.vertical, 34)
        .onDrop(of: [.text], delegate: FolderGridOuterDropDelegate(onDragCancelled: onDragCancelled))
    }
}
