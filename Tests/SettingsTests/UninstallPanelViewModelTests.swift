import Catalog
import Foundation
import Testing
import Uninstall
@testable import Settings

/// Holds a size measurement open until the test lets it finish, so a checkbox
/// can be changed while the measurement is still pending.
private actor Gate {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

@Suite("UninstallPanelViewModel")
@MainActor
struct UninstallPanelViewModelTests {
    private func makeRecord(bundleURL: URL) -> ApplicationRecord {
        ApplicationRecord(
            id: StableAppID(
                bundleURL: bundleURL,
                bundleIdentifier: "com.example.uninstall-test",
                teamIdentifier: nil
            ),
            bundleIdentifier: "com.example.uninstall-test",
            bundleURL: bundleURL,
            executableURL: nil,
            displayName: "Uninstall Test",
            originalDisplayName: "Uninstall Test",
            bundleVersion: "1.0",
            teamIdentifier: nil,
            category: nil,
            sourceID: "test",
            isSystemProtected: false,
            isBackgroundOnly: false,
            iconCacheKey: "uninstall-test",
            canLaunch: false,
            canOpenNewInstance: false,
            lastSeenModificationDate: Date(timeIntervalSince1970: 0)
        )
    }

    private func makeBlockedStore() throws -> (root: URL, store: OperationReportStore) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let blocker = root.appendingPathComponent("not-a-directory")
        try Data("blocker".utf8).write(to: blocker)
        return (root, OperationReportStore(directory: blocker))
    }

    private func allRows(_ viewModel: UninstallPanelViewModel) -> [UninstallPanelViewModel.Row] {
        viewModel.rowsBySection.values.flatMap { $0 }
    }

    private func confirm(_ viewModel: UninstallPanelViewModel) async -> Bool {
        await withCheckedContinuation { continuation in
            viewModel.confirmMoveToTrash { continuation.resume(returning: $0) }
        }
    }

    @Test("report failure leaves completed removal outcomes visible and blocks re-entry")
    func reportFailureIsDistinctFromRemovalFailure() async throws {
        let (root, store) = try makeBlockedStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let viewModel = UninstallPanelViewModel(
            record: makeRecord(bundleURL: root.appendingPathComponent("Missing.app")),
            allRecords: [],
            operationReportStore: store
        )
        await viewModel.waitUntilLoaded()

        let finishedCleanly = await confirm(viewModel)

        #expect(finishedCleanly == false)
        #expect(viewModel.lastOutcomes.count == 1)
        #expect(viewModel.lastOutcomes[0].succeeded == true)
        #expect(viewModel.failedRemovalCount == 0)
        #expect(viewModel.operationReportError != nil)
        #expect(viewModel.hasConfirmedRemoval)
        #expect(viewModel.isRecordingOperationReport == false)

        // A second confirmation does nothing.
        #expect(await confirm(viewModel) == false)
        #expect(viewModel.lastOutcomes.count == 1)
    }

    @Test("successful report keeps the removal result successful and allows close callback")
    func successfulReportSignalsClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reportDirectory = root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let viewModel = UninstallPanelViewModel(
            record: makeRecord(bundleURL: root.appendingPathComponent("Missing.app")),
            allRecords: [],
            operationReportStore: OperationReportStore(directory: reportDirectory)
        )
        await viewModel.waitUntilLoaded()

        let finishedCleanly = await confirm(viewModel)

        #expect(finishedCleanly)
        #expect(viewModel.lastOutcomes.count == 1)
        #expect(viewModel.lastOutcomes[0].succeeded == true)
        #expect(viewModel.operationReportError == nil)
        #expect(viewModel.hasConfirmedRemoval)
        #expect(viewModel.isRecordingOperationReport == false)
    }

    /// Measuring a big folder takes long enough to uncheck something in the
    /// meantime. The measurement used to put back a copy of the row taken
    /// before the wait, re-selecting what the user had just left out — and the
    /// confirmation then moved it to Trash.
    @Test("unchecking a row while sizes are still being measured sticks")
    func uncheckSurvivesSizeMeasurement() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = Gate()

        let viewModel = UninstallPanelViewModel(
            record: makeRecord(bundleURL: root.appendingPathComponent("Missing.app")),
            allRecords: [],
            operationReportStore: OperationReportStore(directory: root),
            measureSize: { _ in
                await gate.wait()
                return 42
            }
        )
        for _ in 0..<2_000 where viewModel.isLoadingPlan {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        let row = try #require(allRows(viewModel).first)
        #expect(row.isChecked)
        #expect(viewModel.isComputingSizes)

        viewModel.setChecked(false, rowID: row.id)
        await gate.open()
        await viewModel.waitUntilLoaded()

        let after = try #require(allRows(viewModel).first { $0.id == row.id })
        #expect(after.isChecked == false)
        #expect(after.sizeInBytes == 42)
    }

    @Test("confirming with nothing selected does nothing and can be done again")
    func nothingSelectedDoesNotConfirm() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let viewModel = UninstallPanelViewModel(
            record: makeRecord(bundleURL: root.appendingPathComponent("Missing.app")),
            allRecords: [],
            operationReportStore: OperationReportStore(directory: root),
            measureSize: { _ in nil }
        )
        await viewModel.waitUntilLoaded()
        for row in allRows(viewModel) { viewModel.setChecked(false, rowID: row.id) }

        let finishedCleanly = await confirm(viewModel)

        #expect(finishedCleanly == false)
        #expect(viewModel.hasConfirmedRemoval == false)
        #expect(viewModel.lastOutcomes.isEmpty)
    }
}
