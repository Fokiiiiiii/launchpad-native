import CoreGraphics
import CoreImage
import Foundation
import ImageIO
import Testing
import UniformTypeIdentifiers
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

/// Writes a flat-coloured image of the given pixel size, optionally tagged with
/// an EXIF orientation the way a camera stores a photo taken sideways.
private func writeWallpaper(width: Int, height: Int, type: UTType, orientation: Int? = nil, in directory: URL) throws -> URL {
    let context = try #require(CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ))
    context.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let image = try #require(context.makeImage())
    let url = directory.appendingPathComponent("wallpaper.\(type.preferredFilenameExtension ?? "image")")
    let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil))
    var properties: [CFString: Any] = [:]
    if let orientation {
        properties[kCGImagePropertyOrientation] = orientation
    }
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    #expect(CGImageDestinationFinalize(destination))
    return url
}

private func temporaryDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

/// The blur works on a 960-pixel image whatever the source, so a large
/// wallpaper has to be decoded at that size rather than whole — the default
/// macOS 27 one is 6016x6016, and decoding it in full cost about 170MB at peak.
@Test
func aStaticWallpaperIsDecodedAtTheSizeTheBlurUses() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = try writeWallpaper(width: 3_000, height: 2_000, type: .png, in: directory)

    let image = try #require(await WallpaperImageCache.loadSourceImage(WallpaperSource(kind: .staticImage, url: url)))

    #expect(image.extent.width == WallpaperImageCache.blurInputMaxDimension)
    #expect(image.extent.height == 640)
}

/// A photo taken sideways is stored landscape with an orientation tag. The
/// desktop shows it upright, so the launcher's copy has to be upright too.
@Test
func aStaticWallpaperIsShownTheWayItsOrientationSays() async throws {
    let directory = try temporaryDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    // 6: the stored pixels are rotated 90 degrees from how the photo is seen.
    let url = try writeWallpaper(width: 3_000, height: 2_000, type: .jpeg, orientation: 6, in: directory)

    let image = try #require(await WallpaperImageCache.loadSourceImage(WallpaperSource(kind: .staticImage, url: url)))

    #expect(image.extent.width == 640)
    #expect(image.extent.height == WallpaperImageCache.blurInputMaxDimension)
}
