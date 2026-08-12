import Foundation
import Testing
@testable import Launcher

@Test
func resolverPrefersUsableStaticDesktopImage() {
    let desktopURL = URL(fileURLWithPath: "/tmp/current-wallpaper.jpg")
    let configuredURL = URL(fileURLWithPath: "/tmp/aerial.mov")

    let source = TesseraWallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: configuredURL,
        isUsableFile: { _ in true }
    )

    #expect(source.kind == .staticImage)
    #expect(source.url == desktopURL)
}

@Test
func resolverUsesConfiguredAerialWhenWorkspaceReportsDefaultDesktop() {
    let desktopURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    let configuredURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/Aerial.mov")

    let source = TesseraWallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: configuredURL,
        isUsableFile: { _ in true }
    )

    #expect(source.kind == .aerialVideo)
    #expect(source.url == configuredURL)
}

@Test
func resolverReturnsUnavailableInsteadOfDefaultDesktopWhenConfiguredSourceCannotBeRead() {
    let desktopURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    let configuredURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/Missing.mov")

    let source = TesseraWallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: configuredURL,
        isUsableFile: { url in url.lastPathComponent != "Missing.mov" }
    )

    #expect(source == .unavailable)
}

@Test
func resolverClassifiesDirectMovieWorkspaceSourceAsAerial() {
    let desktopURL = URL(fileURLWithPath: "/tmp/current-wallpaper.m4v")

    let source = TesseraWallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: nil,
        isUsableFile: { _ in true }
    )

    #expect(source.kind == .aerialVideo)
    #expect(source.url == desktopURL)
}

@Test
func wallpaperWindowCandidateFilteringRejectsUnrelatedWindows() {
    let valid = TesseraWallpaperWindowCandidate(
        windowID: 1545,
        ownerName: "Dock",
        windowName: "Wallpaper-1",
        layer: -2_147_483_624,
        bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        isOnscreen: true,
        alpha: 1
    )
    let unrelatedName = TesseraWallpaperWindowCandidate(
        windowID: 2000,
        ownerName: "Dock",
        windowName: "Dock",
        layer: -2_147_483_624,
        bounds: valid.bounds,
        isOnscreen: true,
        alpha: 1
    )
    let unrelatedLayer = TesseraWallpaperWindowCandidate(
        windowID: 2001,
        ownerName: "Safari",
        windowName: "Wallpaper Preview",
        layer: 0,
        bounds: valid.bounds,
        isOnscreen: true,
        alpha: 1
    )

    #expect(TesseraWallpaperSourceResolver.isWallpaperWindowCandidate(valid))
    #expect(!TesseraWallpaperSourceResolver.isWallpaperWindowCandidate(unrelatedName))
    #expect(!TesseraWallpaperSourceResolver.isWallpaperWindowCandidate(unrelatedLayer))
}

@Test
func wallpaperWindowSelectionPrefersTargetDisplayAndOnscreenLayer() {
    let targetBounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    let targetWindow = TesseraWallpaperWindowCandidate(
        windowID: 1545,
        ownerName: "Dock",
        windowName: "Wallpaper-1",
        layer: -2_147_483_624,
        bounds: targetBounds,
        isOnscreen: true,
        alpha: 1
    )
    let offscreenTarget = TesseraWallpaperWindowCandidate(
        windowID: 1951,
        ownerName: "壁紙",
        windowName: "Offscreen Wallpaper Window",
        layer: -2_147_483_625,
        bounds: targetBounds,
        isOnscreen: false,
        alpha: 1
    )
    let otherDisplay = TesseraWallpaperWindowCandidate(
        windowID: 3000,
        ownerName: "Dock",
        windowName: "Wallpaper-2",
        layer: -2_147_483_624,
        bounds: CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080),
        isOnscreen: true,
        alpha: 1
    )

    let selected = TesseraWallpaperSourceResolver.selectWallpaperWindow(
        candidates: [offscreenTarget, otherDisplay, targetWindow],
        targetBounds: targetBounds
    )

    #expect(selected?.windowID == targetWindow.windowID)
}

@Test
func wallpaperWindowSelectionDoesNotBorrowAnotherDisplay() {
    let targetBounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    let otherDisplay = TesseraWallpaperWindowCandidate(
        windowID: 3000,
        ownerName: "Dock",
        windowName: "Wallpaper-2",
        layer: -2_147_483_624,
        bounds: CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080),
        isOnscreen: true,
        alpha: 1
    )

    #expect(TesseraWallpaperSourceResolver.selectWallpaperWindow(
        candidates: [otherDisplay],
        targetBounds: targetBounds
    ) == nil)
}

@Test
func resolverPrefersWindowCaptureBeforeWorkspaceAndConfiguredSources() {
    let desktopURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    let configuredURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/Aerial.mov")
    let candidate = TesseraWallpaperWindowCandidate(
        windowID: 1545,
        ownerName: "Dock",
        windowName: "Wallpaper-1",
        layer: -2_147_483_624,
        bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        isOnscreen: true,
        alpha: 1
    )

    let source = TesseraWallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: configuredURL,
        windowCandidates: [candidate],
        targetBounds: candidate.bounds,
        isUsableFile: { _ in true }
    )

    #expect(source.kind == .windowCapture)
    #expect(source.windowID == candidate.windowID)
    #expect(source.url == nil)
    #expect(source.captureBounds == candidate.bounds)
}

@Test
func resolverFallsBackToConfiguredAerialWhenNoWallpaperWindowMatches() {
    let desktopURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    let configuredURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/Aerial.mov")

    let source = TesseraWallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: configuredURL,
        windowCandidates: [],
        targetBounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        isUsableFile: { _ in true }
    )

    #expect(source.kind == .aerialVideo)
    #expect(source.url == configuredURL)
}
