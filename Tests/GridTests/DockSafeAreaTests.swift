import CoreGraphics
import Testing
@testable import Grid

@Test func preservesTheVisibleFrameInsetWhenDockFramesAreUnavailable() {
    let inset = DockSafeArea.bottomInset(
        hideDock: false,
        screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 96, width: 1600, height: 904),
        dockFrames: []
    )

    #expect(inset == 96)
}

@Test func usesAVisibleAutoHiddenBottomDockWhenVisibleFrameHasNoInset() {
    let inset = DockSafeArea.bottomInset(
        hideDock: false,
        screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        dockFrames: [CGRect(x: 420, y: 0, width: 760, height: 108)]
    )

    #expect(inset == 108)
}

@Test func ignoresSideDocksForTheBottomInset() {
    let inset = DockSafeArea.bottomInset(
        hideDock: false,
        screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 100, y: 0, width: 1500, height: 1000),
        dockFrames: [CGRect(x: 0, y: 150, width: 100, height: 700)]
    )

    #expect(inset == 0)
}

@Test func ignoresFullscreenSupportWindowsOwnedByDock() {
    let inset = DockSafeArea.bottomInset(
        hideDock: false,
        screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        dockFrames: [
            CGRect(x: 0, y: 0, width: 1600, height: 1000),
            CGRect(x: 420, y: 0, width: 760, height: 108)
        ]
    )

    #expect(inset == 108)
}

@Test func reservesNothingWhenTheUserChoseToHideTheDock() {
    let inset = DockSafeArea.bottomInset(
        hideDock: true,
        screenFrame: CGRect(x: 0, y: 0, width: 1600, height: 1000),
        visibleFrame: CGRect(x: 0, y: 96, width: 1600, height: 904),
        dockFrames: [CGRect(x: 420, y: 0, width: 760, height: 108)]
    )

    #expect(inset == 0)
}

@Test func convertsWindowServerBoundsIntoAppKitCoordinates() {
    let frame = DockSafeArea.appKitFrame(
        fromWindowServerFrame: CGRect(x: 420, y: 892, width: 760, height: 108),
        desktopMaxY: 1_000
    )

    #expect(frame == CGRect(x: 420, y: 0, width: 760, height: 108))
}

@Test func convertsAStackedDisplayUsingItsOwnCoordinateOrigin() {
    // The upper display occupies negative Quartz y coordinates while AppKit
    // places the same display above the primary screen at positive y. A
    // global max-y conversion cannot represent both origins reliably.
    let frame = DockSafeArea.appKitFrame(
        fromWindowServerFrame: CGRect(x: 0, y: -108, width: 1920, height: 108),
        windowServerScreenFrame: CGRect(x: 0, y: -1080, width: 1920, height: 1080),
        appKitScreenFrame: CGRect(x: 0, y: 1080, width: 1920, height: 1080)
    )

    #expect(frame == CGRect(x: 0, y: 1080, width: 1920, height: 108))
}
