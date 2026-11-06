import Foundation
import Testing
@testable import Persistence

@Test func theKnownApplicationsSurviveASaveAndLoad() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let store = LayoutStore(directory: dir)
    var document = LayoutDocument.empty
    document.knownApplications[StableAppIdentifier(value: "abc")] =
        KnownApplication(bundleIdentifier: "com.example.app", teamIdentifier: "TEAM")

    try await store.save(document)
    let loaded = await store.load()

    #expect(loaded.knownApplications == document.knownApplications)
}

/// A layout saved before this existed has no such field and must still load.
@Test func aDocumentSavedBeforeTheyWereRememberedStillLoads() throws {
    let encoded = try JSONEncoder().encode(LayoutDocument.empty)
    var json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
    json.removeValue(forKey: "knownApplications")

    let decoded = try JSONDecoder().decode(LayoutDocument.self, from: JSONSerialization.data(withJSONObject: json))

    #expect(decoded.knownApplications.isEmpty)
}
