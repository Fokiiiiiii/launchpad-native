import Foundation
import Testing
@testable import Onboarding

private func freshDefaults() -> UserDefaults {
    let suiteName = "OnboardingStateTests.\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.removePersistentDomain(forName: suiteName)
    return defaults
}

@Test func hasCompletedIsFalseUntilMarked() {
    let defaults = freshDefaults()
    #expect(OnboardingState.hasCompleted(defaults: defaults) == false)

    OnboardingState.markCompleted(defaults: defaults)
    #expect(OnboardingState.hasCompleted(defaults: defaults) == true)
}

@Test func differentDefaultsSuitesAreIndependent() {
    let a = freshDefaults()
    let b = freshDefaults()
    OnboardingState.markCompleted(defaults: a)

    #expect(OnboardingState.hasCompleted(defaults: a) == true)
    #expect(OnboardingState.hasCompleted(defaults: b) == false)
}
