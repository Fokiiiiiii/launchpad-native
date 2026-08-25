import AppKit
import Testing
@testable import DesignSystem

/// These surfaces are decoration placed behind or beside real controls, and
/// they must never answer a hit test. The launcher's search field was
/// unusable for several rounds because a glass background — a *sibling*, drawn
/// underneath — was winning hit tests against it, so every click meant to
/// focus the field reached the launcher's background handler and dismissed the
/// whole window instead. The fix is that these views decline every point;
/// nothing about the view hierarchy prevents the problem from returning.
@Test @MainActor func aPlainGlassSurfaceNeverAnswersAHitTest() {
    let surface = GlassSurfaceFactory.makeBackground(cornerRadius: 12)
    surface.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
    for point in [NSPoint(x: 1, y: 1), NSPoint(x: 100, y: 50), NSPoint(x: 199, y: 99)] {
        #expect(surface.hitTest(point) == nil, "the surface claimed \(point)")
    }
}

/// The card variant nests a clip and a material inside a shadow container.
/// A hit test enters at the container, so that is where it has to be turned
/// away — the panels place this as a sibling behind their content, which is
/// exactly the arrangement that broke the search field.
@Test @MainActor func aCardSurfaceDeclinesHitTestsAtItsRoot() {
    let card = GlassSurfaceFactory.makeCardBackground(cornerRadius: 14)
    card.frame = NSRect(x: 0, y: 0, width: 300, height: 200)
    card.layoutSubtreeIfNeeded()
    for point in [NSPoint(x: 1, y: 1), NSPoint(x: 150, y: 100), NSPoint(x: 299, y: 199)] {
        #expect(card.hitTest(point) == nil, "the card claimed \(point)")
    }
    #expect(card.subviews.isEmpty == false, "the card had no layers to speak of")
}

/// Same arrangement as the panels use: card behind, content in front.
@Test @MainActor func contentAboveACardSurfaceStillReceivesClicks() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 200))
    let card = GlassSurfaceFactory.makeCardBackground(cornerRadius: 14)
    card.frame = container.bounds
    let button = NSButton(frame: container.bounds)
    container.addSubview(card)
    container.addSubview(button)

    #expect(container.hitTest(NSPoint(x: 150, y: 100)) === button)
}

/// A control placed over one of these surfaces has to receive the click. This
/// is the arrangement the search field is actually in.
@Test @MainActor func aControlAboveAGlassSurfaceStillReceivesClicks() {
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 200, height: 100))
    let surface = GlassSurfaceFactory.makeBackground(cornerRadius: 8)
    surface.frame = container.bounds
    let field = NSTextField(frame: container.bounds)
    container.addSubview(surface)
    container.addSubview(field)

    #expect(container.hitTest(NSPoint(x: 100, y: 50)) === field)
}
