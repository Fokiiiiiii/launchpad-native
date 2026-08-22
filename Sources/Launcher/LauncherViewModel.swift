import Catalog
import Diagnostics
import Foundation

/// Drives the launcher's search/selection state. Kept AppKit-free (beyond
/// `NSWorkspace` at the launch call site being the one exception, isolated in
/// `AppLauncher`) so the selection/filtering behavior is unit-testable.
@MainActor
public final class LauncherViewModel {
    public private(set) var allRecords: [ApplicationRecord] = []
    public private(set) var filteredRecords: [ApplicationRecord] = []
    public private(set) var query: String = ""
    public private(set) var selectedIndex: Int?
    /// Controls the LSUIElement candidate policy for every refilter. The
    /// default is true so existing callers show menu-bar applications.
    public private(set) var showMenuBarApplications = true

    /// Called whenever `filteredRecords` or `selectedIndex` changes, so the
    /// view controller can reload/re-highlight without this model knowing
    /// anything about NSCollectionView.
    public var onChange: (() -> Void)?

    public init(showMenuBarApplications: Bool = true) {
        self.showMenuBarApplications = showMenuBarApplications
    }

    public func setShowMenuBarApplications(_ value: Bool) {
        guard showMenuBarApplications != value else { return }
        showMenuBarApplications = value
        refilter()
    }

    public func setRecords(_ records: [ApplicationRecord]) {
        allRecords = records
        refilter()
    }

    public func setQuery(_ query: String) {
        self.query = query
        selectedIndex = nil
        refilter()
    }

    public var selectedRecord: ApplicationRecord? {
        guard let selectedIndex, filteredRecords.indices.contains(selectedIndex) else { return nil }
        return filteredRecords[selectedIndex]
    }

    public func moveSelection(by delta: Int) {
        guard !filteredRecords.isEmpty else {
            selectedIndex = nil
            onChange?()
            return
        }
        let current = selectedIndex ?? (delta > 0 ? -1 : 0)
        let next = min(max(current + delta, 0), filteredRecords.count - 1)
        selectedIndex = next
        onChange?()
    }

    public func select(index: Int) {
        guard filteredRecords.indices.contains(index) else { return }
        selectedIndex = index
        onChange?()
    }

    private func refilter() {
        let previouslySelectedID = selectedRecord?.id
        // Phase 9 measurement: this whole call happens synchronously on
        // MainActor while the user is typing — target is <16ms even at
        // catalog sizes around 1,000 apps (one frame at 60Hz).
        let start = DispatchTime.now()
        filteredRecords = LauncherFiltering.filter(
            allRecords,
            query: query,
            showMenuBarApplications: showMenuBarApplications
        )
        let ms = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
        DiagnosticsLog.launcher.info("search filter: \(self.allRecords.count, privacy: .public) records took \(ms, privacy: .public)ms")
        if let previouslySelectedID, let newIndex = filteredRecords.firstIndex(where: { $0.id == previouslySelectedID }) {
            selectedIndex = newIndex
        } else {
            selectedIndex = filteredRecords.isEmpty ? nil : 0
        }
        onChange?()
    }
}
