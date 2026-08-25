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

    public static func apply(to view: NSView, isSelected: Bool) {
        view.wantsLayer = true
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = isSelected ? fill.cgColor : NSColor.clear.cgColor
        view.layer?.borderWidth = isSelected ? 1 : 0
        view.layer?.borderColor = border.cgColor
    }
}
