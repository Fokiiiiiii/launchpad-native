import Foundation
import Testing
@testable import Triggers

private let screen = CGRect(x: 0, y: 0, width: 1920, height: 1080)

@Test func detectsEachCorner() {
    #expect(HotCornerGeometry.corner(at: CGPoint(x: 0, y: 1080), in: screen) == .topLeft)
    #expect(HotCornerGeometry.corner(at: CGPoint(x: 1920, y: 1080), in: screen) == .topRight)
    #expect(HotCornerGeometry.corner(at: CGPoint(x: 0, y: 0), in: screen) == .bottomLeft)
    #expect(HotCornerGeometry.corner(at: CGPoint(x: 1920, y: 0), in: screen) == .bottomRight)
}

@Test func centerOfScreenIsNoCorner() {
    #expect(HotCornerGeometry.corner(at: CGPoint(x: 960, y: 540), in: screen) == nil)
}

@Test func respectsThreshold() {
    #expect(HotCornerGeometry.corner(at: CGPoint(x: 10, y: 1075), in: screen, threshold: 4) == nil)
    #expect(HotCornerGeometry.corner(at: CGPoint(x: 2, y: 1078), in: screen, threshold: 4) == .topLeft)
}

@Test func exitDetectionRequiresMovingWellClear() {
    #expect(HotCornerGeometry.hasExitedCorners(CGPoint(x: 0, y: 1080), in: screen) == false)
    #expect(HotCornerGeometry.hasExitedCorners(CGPoint(x: 100, y: 900), in: screen) == true)
}

/// Multi-display: a corner on the *second* display shouldn't register as a
/// corner of the first display's frame, since corners are per-display.
@Test func cornersAreDisplaySpecific() {
    let secondScreen = CGRect(x: 1920, y: 0, width: 1920, height: 1080)
    #expect(HotCornerGeometry.corner(at: CGPoint(x: 1920, y: 1080), in: screen) == .topRight)
    #expect(HotCornerGeometry.corner(at: CGPoint(x: 1920, y: 1080), in: secondScreen) == .topLeft)
}
