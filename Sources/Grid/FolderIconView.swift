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

    /// Real macOS app icons (`.icns` assets fetched via `NSWorkspace`) have
    /// their own visible margin baked in — Apple's icon canvas leaves
    /// breathing room around the glyph rather than filling the full square
    /// edge-to-edge. A folder tile drawn edge-to-edge at the *same*
    /// bounding-box size as a neighboring app icon therefore reads as
    /// visibly bigger/heavier by contrast, even though the two cells'
    /// actual Auto Layout frames are pixel-identical (confirmed via debug
    /// frame logging) — a real user's side-by-side screenshot of a real
    /// app icon next to a folder confirmed exactly this. Insetting the
    /// whole visible tile mimics that natural margin.
    private var visibleSize: CGFloat { size * 0.86 }
    private var corner: CGFloat { visibleSize * 0.236 }
    private var cellGap: CGFloat { visibleSize * 0.055 }
    private var cellCorner: CGFloat { visibleSize * 0.05 }
    private var pad: CGFloat { visibleSize * 0.13 }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: corner, style: .continuous)
        // No fill behind the tile at all — a real user found the filled
        // background (plus the top-highlight gradient this used to also
        // draw over the whole tile) read as an unwanted "shadow" over the
        // app-less padding/gaps. Only the real icon cells and a hairline
        // outer stroke remain.
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
        .frame(width: visibleSize, height: visibleSize)
        .clipShape(shape)
        .overlay(shape.strokeBorder(.white.opacity(0.18), lineWidth: 0.5))
        .frame(width: size, height: size)
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
