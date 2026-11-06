import CoreGraphics
import Testing
@testable import Launcher

@Test @MainActor
func glassMaterialIntensityClampsAndChangesAllMaterialParametersMonotonically() {
    let belowRange = LauncherBackgroundView.glassMaterialParameters(for: -1)
    let low = LauncherBackgroundView.glassMaterialParameters(for: 0)
    let middle = LauncherBackgroundView.glassMaterialParameters(for: 0.35)
    let high = LauncherBackgroundView.glassMaterialParameters(for: 1)
    let aboveRange = LauncherBackgroundView.glassMaterialParameters(for: 2)

    #expect(belowRange == low)
    #expect(aboveRange == high)
    #expect(low.wallpaperOpacity > middle.wallpaperOpacity)
    #expect(middle.wallpaperOpacity > high.wallpaperOpacity)
    #expect(low.blurRadius < middle.blurRadius)
    #expect(middle.blurRadius < high.blurRadius)
    #expect(low.sheenOpacity < middle.sheenOpacity)
    #expect(middle.sheenOpacity < high.sheenOpacity)
    #expect(middle.wallpaperOpacity == 0.6505)
    #expect(middle.blurRadius == 44)
    #expect(middle.sheenOpacity == 0.35)
}

/// Strength used to change the blur radius without anything noticing, and in glass
/// mode the "blur wallpaper" switch (which glass ignores) made every slider step
/// look like a change.
@Test @MainActor
func theWallpaperIsPreparedAgainOnlyWhenWhatItWasPreparedWithChanged() {
    var glass = LauncherBackgroundView.Configuration()
    glass.mode = .glass
    glass.materialIntensity = 0.35
    glass.blursWallpaper = false
    let prepared = LauncherBackgroundView.requestedBlurRadius(for: glass)

    #expect(!LauncherBackgroundView.needsWallpaperReload(lastMode: .glass, lastRadius: prepared, configuration: glass),
            "an unchanged glass configuration asked for a new image")

    glass.materialIntensity = 0.36
    #expect(!LauncherBackgroundView.needsWallpaperReload(lastMode: .glass, lastRadius: prepared, configuration: glass),
            "a tiny strength step decoded the wallpaper again")

    glass.materialIntensity = 0.9
    #expect(LauncherBackgroundView.needsWallpaperReload(lastMode: .glass, lastRadius: prepared, configuration: glass),
            "a large strength change left the blur as it was")

    var wallpaper = LauncherBackgroundView.Configuration()
    wallpaper.mode = .wallpaper
    #expect(LauncherBackgroundView.needsWallpaperReload(lastMode: .glass, lastRadius: prepared, configuration: wallpaper))
    #expect(LauncherBackgroundView.needsWallpaperReload(lastMode: nil, lastRadius: nil, configuration: wallpaper))

    let blurred = LauncherBackgroundView.requestedBlurRadius(for: wallpaper)
    wallpaper.blursWallpaper = false
    #expect(LauncherBackgroundView.needsWallpaperReload(lastMode: .wallpaper, lastRadius: blurred, configuration: wallpaper))
}

@Test @MainActor
func wallpaperBlurStaysSubtle() {
    #expect(LauncherBackgroundView.wallpaperBlurRadius(isEnabled: true) == 8)
    #expect(LauncherBackgroundView.wallpaperBlurRadius(isEnabled: false) == 0)
}
