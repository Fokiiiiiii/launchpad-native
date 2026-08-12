import Foundation
import Testing
@testable import Settings

@Test("settings window stays close to the Tessera compact reference")
func settingsWindowUsesCompactMetrics() {
    #expect(SettingsWindowMetrics.width == 360)
    #expect(SettingsWindowMetrics.height == 480)
    #expect(SettingsWindowMetrics.size == CGSize(width: 360, height: 480))
}
