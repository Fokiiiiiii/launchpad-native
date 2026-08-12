import Catalog
import Foundation
import Testing
import Uninstall
@testable import Settings

@MainActor
private final class RemovalOutcomeBox {
    var value: [RemovalOutcome] = []
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

    @Test("report failure leaves completed removal outcomes visible and blocks re-entry")
    func reportFailureIsDistinctFromRemovalFailure() async throws {
        let (root, store) = try makeBlockedStore()
        defer { try? FileManager.default.removeItem(at: root) }

        let record = makeRecord(
            bundleURL: root.appendingPathComponent("Missing.app")
        )
        let viewModel = UninstallPanelViewModel(
            record: record,
            allRecords: [],
            operationReportStore: store
        )
        let outcomesBox = RemovalOutcomeBox()

        let reportSaved = await withCheckedContinuation { continuation in
            outcomesBox.value = viewModel.confirmMoveToTrash { saved in
                continuation.resume(returning: saved)
            }
        }

        #expect(reportSaved == false)
        #expect(outcomesBox.value.count == 1)
        #expect(outcomesBox.value[0].succeeded == true)
        #expect(viewModel.operationReportError != nil)
        #expect(viewModel.hasConfirmedRemoval)
        #expect(viewModel.isRecordingOperationReport == false)
        #expect(viewModel.confirmMoveToTrash().isEmpty)
    }

    @Test("successful report keeps the removal result successful and allows close callback")
    func successfulReportSignalsClose() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let reportDirectory = root.appendingPathComponent("reports")
        try FileManager.default.createDirectory(at: reportDirectory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let record = makeRecord(
            bundleURL: root.appendingPathComponent("Missing.app")
        )
        let viewModel = UninstallPanelViewModel(
            record: record,
            allRecords: [],
            operationReportStore: OperationReportStore(directory: reportDirectory)
        )
        let outcomesBox = RemovalOutcomeBox()

        let reportSaved = await withCheckedContinuation { continuation in
            outcomesBox.value = viewModel.confirmMoveToTrash { saved in
                continuation.resume(returning: saved)
            }
        }

        #expect(reportSaved)
        #expect(outcomesBox.value.count == 1)
        #expect(outcomesBox.value[0].succeeded == true)
        #expect(viewModel.operationReportError == nil)
        #expect(viewModel.hasConfirmedRemoval)
        #expect(viewModel.isRecordingOperationReport == false)
    }
}
