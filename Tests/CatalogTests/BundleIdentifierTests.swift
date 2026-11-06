import Foundation
import Testing
@testable import Catalog

@Test func ordinaryIdentifiersAreSafeFileNames() {
    for identifier in ["com.apple.finder", "com.example.My-App", "org.foo_bar.app2", "A", "com.example.app-1700000000"] {
        #expect(BundleIdentifier.isSafeFileName(identifier), "\(identifier)")
    }
}

/// Each of these would, pasted into a path under ~/Library, name something
/// other than a folder of that app's own.
@Test func identifiersThatCouldLeaveTheirFolderAreNotSafe() {
    let hostile = [
        "", "../../Documents", "a/b", "/etc", "com.example/../..", "..", ".hidden", "-flag",
        "name with space", "x\u{0}y", "tab\there", String(repeating: "a", count: 256),
    ]
    for identifier in hostile {
        #expect(!BundleIdentifier.isSafeFileName(identifier), "\(identifier.debugDescription)")
    }
}

@Test func aSafeIdentifierKeepsItsNameAndAnUnsafeOneGetsAHarmlessDistinctOne() {
    #expect(BundleIdentifier.fileName(for: "com.example.app") == "com.example.app")

    let first = BundleIdentifier.fileName(for: "../../Documents")
    let second = BundleIdentifier.fileName(for: "../../Desktop")
    #expect(BundleIdentifier.isSafeFileName(first))
    #expect(BundleIdentifier.isSafeFileName(second))
    #expect(first != second)
    #expect(first == BundleIdentifier.fileName(for: "../../Documents"))
}
