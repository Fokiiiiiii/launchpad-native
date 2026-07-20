import Foundation

public enum ScreenCorner: String, Codable, Sendable, CaseIterable {
    case topLeft, topRight, bottomLeft, bottomRight
}

/// Pure geometry, kept free of `NSScreen`/`NSEvent` so it's testable without
/// a display. Coordinates follow AppKit's convention (origin bottom-left, y
/// increases upward) since that's what `NSEvent.mouseLocation`/`NSScreen.frame`
/// use.
public enum HotCornerGeometry {
    public static func corner(at point: CGPoint, in screenFrame: CGRect, threshold: CGFloat = 4) -> ScreenCorner? {
        let nearLeft = point.x <= screenFrame.minX + threshold
        let nearRight = point.x >= screenFrame.maxX - threshold
        let nearTop = point.y >= screenFrame.maxY - threshold
        let nearBottom = point.y <= screenFrame.minY + threshold

        if nearLeft && nearTop { return .topLeft }
        if nearRight && nearTop { return .topRight }
        if nearLeft && nearBottom { return .bottomLeft }
        if nearRight && nearBottom { return .bottomRight }
        return nil
    }

    /// True once the point has moved far enough from every corner to count
    /// as "left the corner" — used to re-arm a corner so it doesn't refire
    /// every frame while the pointer sits in it.
    public static func hasExitedCorners(_ point: CGPoint, in screenFrame: CGRect, threshold: CGFloat = 4, exitMargin: CGFloat = 12) -> Bool {
        corner(at: point, in: screenFrame, threshold: threshold + exitMargin) == nil
    }
}
