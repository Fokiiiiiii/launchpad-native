import AppKit
import Localization
import SwiftUI
import UniformTypeIdentifiers

/// One app tile inside an opened folder's grid — adapted directly from the
/// user-supplied "Tessera" design reference's `AppTile` (icon branch) and
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
    /// Real, confirmed report ("フォルダ内だとアプリの並び替えができな
    /// い"): called when another tile (identified by its own `id`) is
    /// dropped onto this one. Uses the older `NSItemProvider`-based
    /// `.onDrag`/`.onDrop` rather than the newer `Transferable`-based
    /// `.draggable`/`.dropDestination` (macOS 13+) — an earlier pass used
    /// the latter and it silently never worked in practice, confirmed by
    /// the user after shipping. The most likely cause: this tile is a
    /// `Button` with its own `.simultaneousGesture(DragGesture(
    /// minimumDistance: 0))` for press feedback, and on macOS a `Button`'s
    /// AppKit-level mouseDown tracking loop can win out over
    /// `.draggable`'s own (newer, less AppKit-interop-tested) drag
    /// recognizer before it ever gets a chance to start a session.
    /// `.onDrag`/`.onDrop` predates `Transferable` by years and has a much
    /// longer track record coexisting with AppKit-hosted SwiftUI content
    /// specifically (this codebase's `FolderOverlayTileView` is hosted via
    /// `NSHostingView` inside a hand-built AppKit overlay, not a native
    /// SwiftUI `App` lifecycle) — matches the main grid's own
    /// `ItemDragSession` in *not* being the newest-available API, for the
    /// same practical reason.
    let onReorder: (_ draggedID: String) -> Void
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
        // `NSString` conforms to `NSItemProviderWriting`/`-Reading` out of
        // the box — the payload is just this tile's own `id`, which
        // `FolderContentsViewController.reorderTile` uses to look up both
        // the dragged and dropped-on items' current positions.
        .onDrag { NSItemProvider(object: tile.id as NSString) }
        .onDrop(of: [.text], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: NSString.self) { reading, _ in
                guard let draggedID = reading as? String, draggedID != tile.id else { return }
                DispatchQueue.main.async {
                    tile.onReorder(draggedID)
                }
            }
            return true
        }
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
        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
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
}

/// Adapted directly from the Tessera reference's `FolderOverlay`'s inner
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

    var body: some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.flexible(), spacing: 0), count: max(columns, 1)),
            spacing: 26
        ) {
            ForEach(model.tiles) { tile in
                FolderOverlayTileView(tile: tile, iconSize: iconSize)
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 34)
    }
}
