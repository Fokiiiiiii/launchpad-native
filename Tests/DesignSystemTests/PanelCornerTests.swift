import AppKit
import Testing
@testable import DesignSystem

/// On macOS 27 the panels draw their card at the radius the system gives its
/// own windows. `PanelCorner` holds that radius as a constant, so these tests
/// hold the constant against what AppKit itself reports: if a later system
/// rounds its windows differently, this fails instead of the panels quietly
/// looking out of place.
@available(macOS 27, *)
private final class ConcentricProbeView: NSView {
    override var cornerConfiguration: NSViewCornerConfiguration? {
        .uniformCorners(radius: .containerConcentric)
    }
}

@Test @MainActor func thePanelRadiusOnMacOS27IsTheSystemWindowRadius() throws {
    guard #available(macOS 27, *) else { return }
    let window = NSWindow(
        contentRect: NSRect(x: -30_000, y: -30_000, width: 600, height: 500),
        styleMask: [.titled, .closable, .fullSizeContentView],
        backing: .buffered,
        defer: false
    )
    window.isReleasedWhenClosed = false
    let probe = ConcentricProbeView(frame: NSRect(x: 0, y: 0, width: 600, height: 500))
    window.contentView = probe
    window.orderBack(nil)
    defer { window.orderOut(nil) }
    probe.layoutSubtreeIfNeeded()

    let radii = try #require(probe.effectiveCornerRadii)
    for corner in [radii.topLeft, radii.topRight, radii.bottomLeft, radii.bottomRight] {
        #expect(corner == PanelCorner.macOS27WindowRadius)
    }
    #expect(PanelCorner.radius(beforeMacOS27: 13) == PanelCorner.macOS27WindowRadius)
    #expect(PanelCorner.radius(beforeMacOS27: 22) == PanelCorner.macOS27WindowRadius)
}

/// Earlier systems keep every panel exactly as it was.
@Test func panelsKeepTheirOwnRadiusBeforeMacOS27() {
    #expect(PanelCorner.radius(beforeMacOS27: 13, onMacOS27: false) == 13)
    #expect(PanelCorner.radius(beforeMacOS27: 22, onMacOS27: false) == 22)
    #expect(PanelCorner.radius(beforeMacOS27: 22, onMacOS27: true) == PanelCorner.macOS27WindowRadius)
}
