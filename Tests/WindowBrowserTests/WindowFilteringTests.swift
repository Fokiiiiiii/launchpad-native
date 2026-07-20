import Foundation
import Testing
@testable import WindowBrowser

private func window(id: Int, title: String, bundleID: String?, frame: CGRect, onScreen: Bool = true) -> WindowInfo {
    WindowInfo(id: id, title: title, ownerBundleIdentifier: bundleID, ownerProcessID: 1, frame: frame, isOnScreen: onScreen)
}

@Test func excludesKnownSystemOwners() {
    let dockWindow = window(id: 1, title: "", bundleID: "com.apple.dock", frame: CGRect(x: 0, y: 0, width: 1000, height: 1000))
    #expect(WindowFiltering.isUserWindow(dockWindow, excludingBundleIdentifiers: ["com.apple.dock"]) == false)
}

@Test func excludesOffScreenWindows() {
    let hidden = window(id: 2, title: "Hidden", bundleID: "com.example.app", frame: CGRect(x: 0, y: 0, width: 500, height: 500), onScreen: false)
    #expect(WindowFiltering.isUserWindow(hidden, excludingBundleIdentifiers: []) == false)
}

@Test func excludesTinyAuxiliaryWindows() {
    let tiny = window(id: 3, title: "", bundleID: "com.example.app", frame: CGRect(x: 0, y: 0, width: 20, height: 20))
    #expect(WindowFiltering.isUserWindow(tiny, excludingBundleIdentifiers: []) == false)
}

@Test func includesNormalAppWindow() {
    let normal = window(id: 4, title: "Document.txt", bundleID: "com.example.app", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    #expect(WindowFiltering.isUserWindow(normal, excludingBundleIdentifiers: []) == true)
}

@Test func filtersByBundleIdentifier() {
    let windows = [
        window(id: 1, title: "A", bundleID: "com.example.a", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
        window(id: 2, title: "B", bundleID: "com.example.b", frame: CGRect(x: 0, y: 0, width: 800, height: 600)),
        window(id: 3, title: "A2", bundleID: "com.example.a", frame: CGRect(x: 0, y: 0, width: 800, height: 600))
    ]
    let result = WindowFiltering.windows(for: "com.example.a", in: windows)
    #expect(result.map(\.id) == [1, 3])
}
