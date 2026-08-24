import AppKit

/// The selection treatment shared by the grid's cells and the search
/// results'. Both draw it on a view sized to hug the icon and its label
/// rather than the whole slot: an early version filled the entire ~290x285pt
/// cell around a much smaller icon, which read as a large, mostly-empty
/// rectangle. The two were fixed the same way and then kept the same eleven
/// lines in two places, where only one of them would have been updated next.
@MainActor
public enum SelectionHighlight {
    public static func apply(to view: NSView, isSelected: Bool) {
        view.layer?.cornerRadius = 16
        view.layer?.cornerCurve = .continuous
        view.layer?.backgroundColor = isSelected
            ? NSColor.white.withAlphaComponent(0.10).cgColor
            : NSColor.clear.cgColor
        view.layer?.borderWidth = isSelected ? 1 : 0
        view.layer?.borderColor = NSColor.white.withAlphaComponent(0.20).cgColor
    }
}
