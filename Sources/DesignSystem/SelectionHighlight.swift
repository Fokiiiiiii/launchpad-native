import AppKit

/// The tile a selected icon sits on.
///
/// Keyboard selection has to be visible at a glance across a whole page of
/// icons, on top of a wallpaper that can be any colour. A wash of translucent
/// white reads as a smudge over a bright wallpaper; a dark, saturated tile
/// holds its shape against anything behind it and leaves the icon itself the
/// brightest thing inside it.
///
/// Shared by the grid and the search results so a selection looks the same
/// wherever the arrow keys move it.
@MainActor
public enum SelectionHighlight {
    /// Deep indigo rather than neutral black: against a dark wallpaper a black
    /// tile disappears, and against a bright one it reads as a hole.
    private static let fill = NSColor(srgbRed: 0.14, green: 0.11, blue: 0.42, alpha: 0.92)
    private static let border = NSColor.white.withAlphaComponent(0.16)

    /// A macOS app icon is a rounded square drawn inside a canvas that leaves
    /// a margin around it — the artwork occupies 824 of the canvas's 1024
    /// points. An image view is sized to the canvas, so a tile measured from
    /// the view's own frame is much larger than it looks against the icon
    /// anyone actually sees, and at the sizes this grid uses it overran the
    /// cell entirely.
    private static let artworkFraction: CGFloat = 824.0 / 1024.0
    /// How far the tile extends past the artwork, as a fraction of it.
    private static let artworkMargin: CGFloat = 0.125
    private static let cornerFraction: CGFloat = 0.225

    /// The tile for an icon drawn into a square of `iconViewSide` points.
    ///
    /// - Returns: `inset` is how far each edge sits inside the icon view's own
    ///   frame — positive means the tile is smaller than that frame, which it
    ///   normally is, because the frame includes the icon's margin.
    public static func tileGeometry(iconViewSide: CGFloat) -> (inset: CGFloat, cornerRadius: CGFloat) {
        let side = iconViewSide * artworkFraction * (1 + 2 * artworkMargin)
        return ((iconViewSide - side) / 2, side * cornerFraction)
    }

    public static func apply(to view: NSView, isSelected: Bool) {
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = isSelected ? fill.cgColor : NSColor.clear.cgColor
        view.layer?.borderWidth = isSelected ? 1 : 0
        view.layer?.borderColor = border.cgColor
    }
}
