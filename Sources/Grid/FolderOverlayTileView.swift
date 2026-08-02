import AppKit
import Localization
import SwiftUI

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
}

struct FolderOverlayTileView: View {
    let tile: FolderOverlayTile
    let iconSize: CGFloat

    @State private var hovering = false
    @State private var pressed = false

    private var corner: CGFloat { iconSize * 0.236 }
    private static let snappy = Animation.spring(response: 0.26, dampingFraction: 0.90)

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
        .buttonStyle(.plain)
        .scaleEffect(pressed ? 0.90 : 1)
        .offset(y: hovering ? -2 : 0)
        .animation(Self.snappy, value: hovering)
        .animation(Self.snappy, value: pressed)
        .onHover { hovering = $0 }
        .simultaneousGesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in pressed = true }
                .onEnded { _ in pressed = false }
        )
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
        // Real, confirmed report ("アプリの黒背景"/"フォルダ制作のUiが
        // ひどすぎる長方形だし...何も改善されていない"): the previous
        // fix here (conditioning the shadow's color on `tile.icon != nil`)
        // only addressed the not-yet-loaded case — it didn't touch the
        // real root cause, which persisted even after the icon loaded.
        // The removed `shape.fill(LinearGradient(...))` line used to draw
        // a translucent highlight across the *entire* square regardless of
        // the real icon's own alpha — real macOS app icons (Big Sur-era
        // templates onward) commonly have a transparent margin inside
        // their canvas, so that fill lit up the margin as if it were
        // opaque. Combined with `.shadow()` applying independently to each
        // ZStack primitive (no `compositingGroup()` was present), that
        // fill layer cast its own drop shadow shaped like the *whole
        // square*, not the icon's actual artwork — which is what read as
        // a solid black frame around every icon, even fully loaded ones.
        // The sibling `FolderIconView.swift` hit the identical symptom
        // once (commit 5247ea1, user report "フォルダだけ妙にでかいし
        // なんかアプリがない部分に影をつけるのはやめて") and fixed it by
        // deleting the fill outright — same fix here. `compositingGroup()`
        // is added so the retained `.shadow()` casts from the actual
        // composited result (image + hairline stroke) instead of each
        // ZStack layer independently, so it now hugs the real icon's
        // shape instead of the square bounding box.
        .compositingGroup()
        .shadow(color: tile.icon != nil ? .black.opacity(0.35) : .clear, radius: 6, y: 3)
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
