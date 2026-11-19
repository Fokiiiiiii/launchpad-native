import CoreGraphics
import Testing
@testable import Launcher

@Test @MainActor
func glassPresetsUseDistinctNativeMaterials() {
    #expect(LauncherMaterialSurface.material(for: 0).rawValue == 13)
    #expect(LauncherMaterialSurface.material(for: 0.25).rawValue == 15)
    #expect(LauncherMaterialSurface.material(for: 0.5).rawValue == 6)
    #expect(LauncherMaterialSurface.material(for: 0.75).rawValue == 5)
    #expect(LauncherMaterialSurface.material(for: 1).rawValue == 21)
    let view = LauncherMaterialSurface.makeView()
    #expect(view.blendingMode == .behindWindow)
    #expect(view.state == .active)
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
    #expect(!LauncherBackgroundView.needsWallpaperReload(lastMode: .glass, lastRadius: prepared, configuration: glass),
            "changing the native material should not reload wallpaper")

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
    #expect(LauncherBackgroundView.wallpaperDimOpacity(isBlurred: true) == 0.3)
    #expect(LauncherBackgroundView.wallpaperDimOpacity(isBlurred: false) == 0.2)
    #expect(LauncherBackgroundView.wallpaperBlurRadius(isEnabled: true) == 8)
    #expect(LauncherBackgroundView.wallpaperBlurRadius(isEnabled: false) == 0)
    #expect(LauncherBackgroundView.wallpaperBlurRadius(isEnabled: true, radius: 23) == 23)
    #expect(LauncherBackgroundView.wallpaperBlurRadius(isEnabled: false, radius: 23) == 0)
    #expect(LauncherBackgroundView.wallpaperBlurRadius(isEnabled: true, radius: 50) == 40)
    var configuration = LauncherBackgroundView.Configuration()
    configuration.mode = .wallpaper
    configuration.wallpaperBlurRadius = 23
    #expect(LauncherBackgroundView.needsWallpaperReload(lastMode: .wallpaper, lastRadius: 8, configuration: configuration))
    configuration.wallpaperBlurRadius = 9
    #expect(LauncherBackgroundView.needsWallpaperReload(lastMode: .wallpaper, lastRadius: 8, configuration: configuration))
}

@Test @MainActor
func glassMaterialPresetsClampAndMapToFiveLevels() {
    #expect(LauncherMaterialSurface.presetIndex(for: -1) == 0)
    #expect(LauncherMaterialSurface.presetIndex(for: 0.25) == 1)
    #expect(LauncherMaterialSurface.presetIndex(for: 0.5) == 2)
    #expect(LauncherMaterialSurface.presetIndex(for: 0.75) == 3)
    #expect(LauncherMaterialSurface.presetIndex(for: 2) == 4)
    #expect(LauncherMaterialSurface.presetIndex(for: .nan) == 1)
}
