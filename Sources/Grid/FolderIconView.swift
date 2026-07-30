import SwiftUI

/// The closed folder icon — adapted directly from the user-supplied
/// "Tessera" SwiftUI design reference (`LaunchpadView.swift`'s
/// `AppTile.icon` folder branch + `FolderThumbnail`), not a from-scratch
/// AppKit/Core Graphics reinterpretation of its numbers. Two attempts at
/// hand-translating this into `NSBezierPath`/`CALayer` drawing were both
/// rejected by the user as "妙にフォルダと違う" (subtly wrong in ways that
/// didn't match); this hosts the reference's actual view code (with real
/// `NSImage` icons swapped in for its placeholder `LaunchItem` model)
/// via `NSHostingView` instead, so the rendering is byte-for-byte what the
/// reference produces — SwiftUI's `RoundedRectangle(style: .continuous)`
/// gives the true squircle natively, no CALayer corner-curve workaround
/// needed the way a Core Graphics bitmap required.
struct FolderIconView: View {
    /// Up to 9 real app icons already fetched from `IconCache` — unfilled
    /// slots (fewer than 9 icons) render as a faint placeholder, exactly
    /// matching the reference's own `FolderThumbnail` (a fixed 3x3 grid
    /// regardless of count, never resized).
    let icons: [NSImage]
    let size: CGFloat

    private var corner: CGFloat { size * 0.236 }
    private var cellGap: CGFloat { size * 0.055 }
    private var cellCorner: CGFloat { size * 0.05 }
    private var pad: CGFloat { size * 0.13 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        // No fill behind the tile at all — a real user found the filled
        // background (plus the top-highlight gradient this used to also
        // draw over the whole tile) read as an unwanted "shadow" over the
        // app-less padding/gaps, and made the folder look conspicuously
        // bigger/heavier than neighboring app icons even at the exact same
        // pixel dimensions (confirmed via debug frame logging — the outer
        // frame matches an app icon's exactly; the perceived size
        // difference was purely from this fill's visual weight). Only the
        // real icon cells and a hairline outer stroke remain.
        Grid(horizontalSpacing: cellGap, verticalSpacing: cellGap) {
            ForEach(0..<3, id: \.self) { row in
                GridRow {
                    ForEach(0..<3, id: \.self) { col in
                        let index = row * 3 + col
                        cell(at: index)
                    }
                }
            }
        }
        .padding(pad)
        .frame(width: size, height: size)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
    }

    @ViewBuilder
    private func cell(at index: Int) -> some View {
        let cellShape = RoundedRectangle(cornerRadius: cellCorner, style: .continuous)
        if index < icons.count {
            Image(nsImage: icons[index])
                .resizable()
                .aspectRatio(contentMode: .fill)
                .clipShape(cellShape)
        } else {
            // Fully transparent — no placeholder box at all for an unfilled
            // slot (see this method's caller's doc comment on why a faint
            // fill here was also part of the "shadow" complaint).
            Color.clear
        }
    }
}
