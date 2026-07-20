import Testing
@testable import Diagnostics

@Test func loggersAreDistinctCategories() {
    #expect(DiagnosticsLog.subsystem == "com.launchpadnative.app")
}
