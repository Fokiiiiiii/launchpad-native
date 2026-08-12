import Foundation
import Grid
import Persistence
import Testing
@testable import Settings

@Test @MainActor func failedTriggerTransactionRestoresEveryControl() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("launchpad-settings-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = GridModel(layoutStore: LayoutStore(directory: directory))
    let previous = model.triggerSettings
    var callbackCount = 0
    let viewModel = SettingsViewModel(
        model: model,
        onTriggerSettingsChanged: { _ in
            callbackCount += 1
            return .failed
        },
        onDockVisibilityChanged: { _ in }
    )

    viewModel.f4Enabled = !previous.f4Enabled
    viewModel.hotkeyEnabled = !previous.hotkeyEnabled
    viewModel.multitouchEnabled = !previous.multitouchGestureEnabled
    viewModel.gestureConflictPreventionEnabled = !previous.gestureConflictPreventionEnabled

    for _ in 0..<20 {
        await Task.yield()
    }

    #expect(callbackCount == 1)
    #expect(viewModel.f4Enabled == previous.f4Enabled)
    #expect(viewModel.hotkeyEnabled == previous.hotkeyEnabled)
    #expect(viewModel.multitouchEnabled == previous.multitouchGestureEnabled)
    #expect(viewModel.gestureConflictPreventionEnabled == previous.gestureConflictPreventionEnabled)
    #expect(model.triggerSettings == previous)
}

@Test @MainActor func triggerEditDuringRefreshIsDrainedAfterRefreshCompletes() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("launchpad-settings-refresh-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = GridModel(layoutStore: LayoutStore(directory: directory))
    let previous = model.triggerSettings
    var callbackCount = 0
    var refreshEntered = false
    var releaseRefresh = false
    let viewModel = SettingsViewModel(
        model: model,
        onTriggerSettingsChanged: { _ in
            callbackCount += 1
            if callbackCount == 1 {
                refreshEntered = true
                while !releaseRefresh {
                    await Task.yield()
                }
            }
            return .failed
        },
        onDockVisibilityChanged: { _ in }
    )

    viewModel.refreshF4Status()
    for _ in 0..<20 where !refreshEntered {
        await Task.yield()
    }
    #expect(refreshEntered)

    viewModel.f4Enabled = !previous.f4Enabled
    releaseRefresh = true
    for _ in 0..<80 {
        await Task.yield()
    }

    #expect(callbackCount == 2)
    #expect(model.triggerSettings == previous)
}

@Test @MainActor func trackpadArbitrationFailureIsPublishedSeparatelyFromRawListener() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("launchpad-settings-trackpad-status-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = GridModel(layoutStore: LayoutStore(directory: directory))
    let viewModel = SettingsViewModel(
        model: model,
        onTriggerSettingsChanged: { _ in
            TriggerSettingsApplyResult(
                f4Active: false,
                multitouchActive: true,
                multitouchEventArbitrationActive: false,
                gestureConflictStatus: .unchanged,
                gestureConflictBackup: nil
            )
        },
        onDockVisibilityChanged: { _ in }
    )

    viewModel.refreshF4Status()
    for _ in 0..<20 where !viewModel.multitouchActive {
        await Task.yield()
    }

    #expect(viewModel.multitouchActive)
    #expect(!viewModel.multitouchEventArbitrationActive)
}
