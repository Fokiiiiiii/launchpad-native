import Foundation
import Testing
@testable import Launcher

@Test
func resolverPrefersUsableStaticDesktopImage() {
    let desktopURL = URL(fileURLWithPath: "/tmp/current-wallpaper.jpg")
    let configuredURL = URL(fileURLWithPath: "/tmp/aerial.mov")

    let source = WallpaperSourceResolver.resolve(
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

    let source = WallpaperSourceResolver.resolve(
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

    let source = WallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: configuredURL,
        isUsableFile: { url in url.lastPathComponent != "Missing.mov" }
    )

    #expect(source == .unavailable)
}

@Test
func resolverClassifiesDirectMovieWorkspaceSourceAsAerial() {
    let desktopURL = URL(fileURLWithPath: "/tmp/current-wallpaper.m4v")

    let source = WallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: nil,
        isUsableFile: { _ in true }
    )

    #expect(source.kind == .aerialVideo)
    #expect(source.url == desktopURL)
}

@Test
func wallpaperWindowCandidateFilteringRejectsUnrelatedWindows() {
    let valid = WallpaperWindowCandidate(
        windowID: 1545,
        ownerName: "Dock",
        windowName: "Wallpaper-1",
        layer: -2_147_483_624,
        bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        isOnscreen: true,
        alpha: 1
    )
    let unrelatedName = WallpaperWindowCandidate(
        windowID: 2000,
        ownerName: "Dock",
        windowName: "Dock",
        layer: -2_147_483_624,
        bounds: valid.bounds,
        isOnscreen: true,
        alpha: 1
    )
    let unrelatedLayer = WallpaperWindowCandidate(
        windowID: 2001,
        ownerName: "Safari",
        windowName: "Wallpaper Preview",
        layer: 0,
        bounds: valid.bounds,
        isOnscreen: true,
        alpha: 1
    )

    #expect(WallpaperSourceResolver.isWallpaperWindowCandidate(valid))
    #expect(!WallpaperSourceResolver.isWallpaperWindowCandidate(unrelatedName))
    #expect(!WallpaperSourceResolver.isWallpaperWindowCandidate(unrelatedLayer))
}

@Test
func wallpaperWindowSelectionPrefersTargetDisplayAndOnscreenLayer() {
    let targetBounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    let targetWindow = WallpaperWindowCandidate(
        windowID: 1545,
        ownerName: "Dock",
        windowName: "Wallpaper-1",
        layer: -2_147_483_624,
        bounds: targetBounds,
        isOnscreen: true,
        alpha: 1
    )
    let offscreenTarget = WallpaperWindowCandidate(
        windowID: 1951,
        ownerName: "壁紙",
        windowName: "Offscreen Wallpaper Window",
        layer: -2_147_483_625,
        bounds: targetBounds,
        isOnscreen: false,
        alpha: 1
    )
    let otherDisplay = WallpaperWindowCandidate(
        windowID: 3000,
        ownerName: "Dock",
        windowName: "Wallpaper-2",
        layer: -2_147_483_624,
        bounds: CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080),
        isOnscreen: true,
        alpha: 1
    )

    let selected = WallpaperSourceResolver.selectWallpaperWindow(
        candidates: [offscreenTarget, otherDisplay, targetWindow],
        targetBounds: targetBounds
    )

    #expect(selected?.windowID == targetWindow.windowID)
}

@Test
func wallpaperWindowSelectionDoesNotBorrowAnotherDisplay() {
    let targetBounds = CGRect(x: 0, y: 0, width: 1_920, height: 1_080)
    let otherDisplay = WallpaperWindowCandidate(
        windowID: 3000,
        ownerName: "Dock",
        windowName: "Wallpaper-2",
        layer: -2_147_483_624,
        bounds: CGRect(x: 1_920, y: 0, width: 1_920, height: 1_080),
        isOnscreen: true,
        alpha: 1
    )

    #expect(WallpaperSourceResolver.selectWallpaperWindow(
        candidates: [otherDisplay],
        targetBounds: targetBounds
    ) == nil)
}

@Test
func resolverPrefersFileWallpaperBeforeWindowCapture() {
    let desktopURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    let configuredURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/Aerial.mov")
    let candidate = WallpaperWindowCandidate(
        windowID: 1545,
        ownerName: "Dock",
        windowName: "Wallpaper-1",
        layer: -2_147_483_624,
        bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        isOnscreen: true,
        alpha: 1
    )

    let source = WallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: configuredURL,
        windowCandidates: [candidate],
        targetBounds: candidate.bounds,
        isUsableFile: { _ in true }
    )

    #expect(source.kind == .aerialVideo)
    #expect(source.url == configuredURL)
}

@Test
func resolverUsesWindowCaptureOnlyWhenFileSourcesAreUnavailable() {
    let desktopURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    let configuredURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/Missing.mov")
    let candidate = WallpaperWindowCandidate(
        windowID: 1545,
        ownerName: "Dock",
        windowName: "Wallpaper-1",
        layer: -2_147_483_624,
        bounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        isOnscreen: true,
        alpha: 1
    )

    let source = WallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: configuredURL,
        windowCandidates: [candidate],
        targetBounds: candidate.bounds,
        isUsableFile: { _ in false }
    )

    #expect(source.kind == .windowCapture)
    #expect(source.windowID == candidate.windowID)
}

@Test
func resolverFallsBackToConfiguredAerialWhenNoWallpaperWindowMatches() {
    let desktopURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    let configuredURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/Aerial.mov")

    let source = WallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: configuredURL,
        windowCandidates: [],
        targetBounds: CGRect(x: 0, y: 0, width: 1_920, height: 1_080),
        isUsableFile: { _ in true }
    )

    #expect(source.kind == .aerialVideo)
    #expect(source.url == configuredURL)
}

// MARK: - macOS 27: default wallpaper drawn by an extension

private let defaultProvider = SystemWallpaperStore.defaultProviderIdentifier
private let imageProvider = "com.apple.wallpaper.extension.image"
private let thisDisplay = "37D8832A-2D66-02CA-B9F7-8F30A301B230"
private let otherDisplay = "DD82ED5C-C9E5-4E6D-B00A-FDE89E0C54CF"

/// One Desktop choice, shaped the way `Store/Index.plist` records it.
private func storeEntry(_ provider: String) -> [String: Any] {
    ["Desktop": ["Content": ["Choices": [["Provider": provider, "Files": [Any]()]]]]]
}

@Test
func storeNamesTheProviderEveryEntryForTheDisplayAgreesOn() {
    let store: [String: Any] = [
        "Displays": [thisDisplay: storeEntry(defaultProvider)],
        "Spaces": [
            "space-a": ["Default": storeEntry(defaultProvider), "Displays": [thisDisplay: storeEntry(defaultProvider)]],
            "space-b": ["Default": storeEntry(defaultProvider)],
        ],
    ]
    #expect(SystemWallpaperStore.desktopProvider(in: store, displayUUID: thisDisplay) == defaultProvider)
}

/// The current Space is not knowable through public API, so a display whose
/// Spaces disagree must not be given any one of their wallpapers.
@Test
func storeLeavesTheProviderUnknownWhenSpacesDisagreeForTheDisplay() {
    let store: [String: Any] = [
        "Displays": [thisDisplay: storeEntry(defaultProvider)],
        "Spaces": [
            "space-a": ["Default": storeEntry(defaultProvider)],
            "space-b": ["Displays": [thisDisplay: storeEntry(imageProvider)]],
        ],
    ]
    #expect(SystemWallpaperStore.desktopProvider(in: store, displayUUID: thisDisplay) == nil)
}

/// A Space's default only covers displays it has no entry for — another
/// display's wallpaper, recorded as that Space's default, is not ambiguity.
@Test
func aSpacesOwnEntryForTheDisplayReplacesTheSpacesDefault() {
    let store: [String: Any] = [
        "Spaces": [
            "space-a": [
                "Default": storeEntry(imageProvider),
                "Displays": [thisDisplay: storeEntry(defaultProvider), otherDisplay: storeEntry(imageProvider)],
            ],
        ],
    ]
    #expect(SystemWallpaperStore.desktopProvider(in: store, displayUUID: thisDisplay) == defaultProvider)
    #expect(SystemWallpaperStore.desktopProvider(in: store, displayUUID: otherDisplay) == imageProvider)
}

@Test
func storeFallsBackToItsStoreWideEntriesOnlyWhenNothingIsRecordedForTheDisplay() {
    let allSpaces: [String: Any] = [
        "AllSpacesAndDisplays": storeEntry(defaultProvider),
        "SystemDefault": storeEntry(imageProvider),
    ]
    #expect(SystemWallpaperStore.desktopProvider(in: allSpaces, displayUUID: thisDisplay) == defaultProvider)

    let systemDefaultOnly: [String: Any] = ["SystemDefault": storeEntry(defaultProvider)]
    #expect(SystemWallpaperStore.desktopProvider(in: systemDefaultOnly, displayUUID: nil) == defaultProvider)

    // Recorded for the display, so the store-wide entry is not consulted.
    let displayRecorded: [String: Any] = [
        "Displays": [thisDisplay: storeEntry(imageProvider)],
        "AllSpacesAndDisplays": storeEntry(defaultProvider),
    ]
    #expect(SystemWallpaperStore.desktopProvider(in: displayRecorded, displayUUID: thisDisplay) == imageProvider)
}

@Test
func defaultProviderArtworkFollowsTheAppearance() {
    #expect(SystemWallpaperStore.defaultProviderArtwork(prefersDark: true).lastPathComponent == "TahoeDark.heic")
    #expect(SystemWallpaperStore.defaultProviderArtwork(prefersDark: false).lastPathComponent == "TahoeLight.heic")
}

/// The configured Aerial is the last file resort because it can outlive the
/// wallpaper it named: on macOS 27 it still pointed at an Aerial the update had
/// deleted, while the store said the desktop was the new default.
@Test
func resolverUsesTheStoresArtworkAheadOfTheConfiguredAerial() {
    let desktopURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    let configuredURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/Aerial.mov")
    let artworkURL = SystemWallpaperStore.defaultProviderArtwork(prefersDark: true)

    let source = WallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: configuredURL,
        providerArtworkURL: artworkURL,
        isUsableFile: { _ in true }
    )

    #expect(source.kind == .staticImage)
    #expect(source.url == artworkURL)
}

@Test
func resolverStillPrefersARealWorkspaceImageOverTheStoresArtwork() {
    let desktopURL = URL(fileURLWithPath: "/tmp/current-wallpaper.jpg")
    let artworkURL = SystemWallpaperStore.defaultProviderArtwork(prefersDark: true)

    let source = WallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: nil,
        providerArtworkURL: artworkURL,
        isUsableFile: { _ in true }
    )

    #expect(source.url == desktopURL)
}

@Test
func resolverSkipsArtworkThatIsNotOnDisk() {
    let desktopURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    let configuredURL = URL(fileURLWithPath: "/Library/Application Support/com.apple.idleassetsd/Customer/Aerial.mov")
    let artworkURL = SystemWallpaperStore.defaultProviderArtwork(prefersDark: true)

    let source = WallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: configuredURL,
        providerArtworkURL: artworkURL,
        isUsableFile: { $0 != artworkURL }
    )

    #expect(source.kind == .aerialVideo)
    #expect(source.url == configuredURL)
}

/// Window capture is the last resort: without Screen Recording access macOS 27
/// only ever returns a flat stand-in for the wallpaper window.
@Test
func resolverUsesTheStoresArtworkBeforeCapturingAWallpaperWindow() {
    let desktopURL = URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic")
    let artworkURL = SystemWallpaperStore.defaultProviderArtwork(prefersDark: true)
    let candidate = WallpaperWindowCandidate(
        windowID: 13,
        ownerName: "WindowManager",
        windowName: "Wallpaper",
        layer: -2_147_483_624,
        bounds: CGRect(x: 0, y: 0, width: 1_680, height: 1_050),
        isOnscreen: true,
        alpha: 1
    )

    let source = WallpaperSourceResolver.resolve(
        desktopURL: desktopURL,
        configuredURL: nil,
        providerArtworkURL: artworkURL,
        windowCandidates: [candidate],
        targetBounds: candidate.bounds,
        hasScreenCaptureAccess: true,
        isUsableFile: { $0 == artworkURL }
    )

    #expect(source.kind == .staticImage)
    #expect(source.url == artworkURL)
}

private let windowManagerWallpaper = WallpaperWindowCandidate(
    windowID: 6361,
    ownerName: "WindowManager",
    windowName: "Wallpaper",
    layer: -2_147_483_624,
    bounds: CGRect(x: 0, y: 0, width: 1_680, height: 1_050),
    isOnscreen: true,
    alpha: 1
)

/// macOS 27 draws the desktop in `WindowManager` windows, and without Screen
/// Recording access they come back as a grey stand-in rather than nil.
/// Capturing one painted the launcher grey, so without access they are never
/// chosen — the opaque base is the honest answer when no file source exists.
@Test
func windowManagerWallpaperIsNotCapturedWithoutScreenCaptureAccess() {
    let source = WallpaperSourceResolver.resolve(
        desktopURL: URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic"),
        configuredURL: nil,
        windowCandidates: [windowManagerWallpaper],
        targetBounds: windowManagerWallpaper.bounds,
        hasScreenCaptureAccess: false,
        isUsableFile: { _ in false }
    )

    #expect(source.kind == .unavailable)
}

@Test
func windowManagerWallpaperIsCapturedWithScreenCaptureAccess() {
    let source = WallpaperSourceResolver.resolve(
        desktopURL: URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic"),
        configuredURL: nil,
        windowCandidates: [windowManagerWallpaper],
        targetBounds: windowManagerWallpaper.bounds,
        hasScreenCaptureAccess: true,
        isUsableFile: { _ in false }
    )

    #expect(source.kind == .windowCapture)
    #expect(source.windowID == windowManagerWallpaper.windowID)
}

/// Up to macOS 26 the desktop lived in Dock-owned windows that WindowServer
/// showed as-is without the permission. That has to keep working.
@Test
func dockWallpaperIsStillCapturedWithoutScreenCaptureAccess() {
    let dockWallpaper = WallpaperWindowCandidate(
        windowID: 1545,
        ownerName: "Dock",
        windowName: "Wallpaper-1",
        layer: -2_147_483_624,
        bounds: CGRect(x: 0, y: 0, width: 1_680, height: 1_050),
        isOnscreen: true,
        alpha: 1
    )

    let source = WallpaperSourceResolver.resolve(
        desktopURL: URL(fileURLWithPath: "/System/Library/CoreServices/DefaultDesktop.heic"),
        configuredURL: nil,
        windowCandidates: [windowManagerWallpaper, dockWallpaper],
        targetBounds: dockWallpaper.bounds,
        hasScreenCaptureAccess: false,
        isUsableFile: { _ in false }
    )

    #expect(source.kind == .windowCapture)
    #expect(source.windowID == dockWallpaper.windowID)
}
