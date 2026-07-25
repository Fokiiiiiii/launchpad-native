import AppKit

/// `NSTextField`'s stock cell centers its text within the field's Auto
/// Layout frame implicitly, with no explicit vertical-centering logic of
/// its own — for most fields this looks fine, but the search bar's larger
/// 20pt font inside its 44pt-tall glass capsule showed a small but real
/// vertical offset between the placeholder/typed text and the field's
/// actual visual center (confirmed via a debug-driven screenshot the user
/// sent — "検索欄の文字が少しズレてる"). `drawingRect(forBounds:)` and
/// `placeholderAttributedString`'s rendering both go through this same
/// cell, so overriding it once fixes the placeholder, the live-typed text,
/// and the insertion caret consistently, rather than leaving their
/// positioning to three independently-implicit code paths.
final class SearchFieldCell: NSTextFieldCell {
    override func drawingRect(forBounds rect: NSRect) -> NSRect {
        var rect = super.drawingRect(forBounds: rect)
        let textSize = cellSize(forBounds: rect)
        let heightDelta = rect.height - textSize.height
        if heightDelta > 0 {
            rect.size.height = textSize.height
            rect.origin.y += heightDelta / 2
        }
        return rect
    }
}
