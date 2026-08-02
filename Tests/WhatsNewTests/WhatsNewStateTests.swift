import Foundation
import Testing
@testable import WhatsNew

private func freshDefaults() -> UserDefaults {
    let suiteName = "WhatsNewStateTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Test func lastShownVersionIsNilUntilMarked() {
    let defaults = freshDefaults()
    #expect(WhatsNewState.lastShownVersion(defaults: defaults) == nil)

    WhatsNewState.markShown(version: "2.1.0", defaults: defaults)
    #expect(WhatsNewState.lastShownVersion(defaults: defaults) == "2.1.0")
}

@Test func markingANewerVersionOverwritesTheOldOne() {
    let defaults = freshDefaults()
    WhatsNewState.markShown(version: "2.1.0", defaults: defaults)
    WhatsNewState.markShown(version: "2.2.0", defaults: defaults)

    #expect(WhatsNewState.lastShownVersion(defaults: defaults) == "2.2.0")
}

@Test func differentDefaultsSuitesAreIndependent() {
    let a = freshDefaults()
    let b = freshDefaults()
    WhatsNewState.markShown(version: "2.1.0", defaults: a)

    #expect(WhatsNewState.lastShownVersion(defaults: a) == "2.1.0")
    #expect(WhatsNewState.lastShownVersion(defaults: b) == nil)
}
