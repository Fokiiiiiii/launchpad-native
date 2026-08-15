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
