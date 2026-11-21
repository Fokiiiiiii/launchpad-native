import AppKit
import Foundation
import Grid
import Persistence
import Testing
@testable import Settings

/// Waits for work the view model scheduled on the main actor. The other tests
/// share that actor, so a fixed count of yields could run out before the work
/// got a turn: run together in a release build, a trigger edit was still
/// waiting after twenty.
@MainActor
private func waitUntil(_ condition: () -> Bool) async {
    let deadline = ContinuousClock.now + .seconds(5)
    while !condition(), ContinuousClock.now < deadline {
        try? await Task.sleep(for: .milliseconds(1))
    }
}

/// A login item that is registered but waiting for approval does not start at
/// login. It is shown on, with a notice, and does not flip off the next time the
/// window is opened.
@Test @MainActor func aLoginItemWaitingForApprovalIsShownOnWithANotice() {
    #expect(SettingsViewModel.launchAtLoginState(for: .enabled) == (true, false))
    #expect(SettingsViewModel.launchAtLoginState(for: .requiresApproval) == (true, true))
    #expect(SettingsViewModel.launchAtLoginState(for: .notRegistered) == (false, false))
    #expect(SettingsViewModel.launchAtLoginState(for: .notFound) == (false, false))
}

/// Escape while recording a shortcut cancels it. It used to be recorded as the
/// shortcut itself. Return and Space start a recording without the mouse.
@Test @MainActor func theRecorderTreatsEscapeAsCancelAndReturnOrSpaceAsStart() {
    let plain = NSEvent.ModifierFlags()
    #expect(HotkeyRecorderNSView.keyAction(keyCode: 53, modifiers: plain, isRecording: true) == .cancel)
    #expect(HotkeyRecorderNSView.keyAction(keyCode: 53, modifiers: .command, isRecording: true) == .capture)
    #expect(HotkeyRecorderNSView.keyAction(keyCode: 49, modifiers: .option, isRecording: true) == .capture)
    #expect(HotkeyRecorderNSView.keyAction(keyCode: 49, modifiers: plain, isRecording: false) == .startRecording)
    #expect(HotkeyRecorderNSView.keyAction(keyCode: 36, modifiers: plain, isRecording: false) == .startRecording)
    #expect(HotkeyRecorderNSView.keyAction(keyCode: 0, modifiers: plain, isRecording: false) == .passThrough)
    #expect(HotkeyRecorderNSView.keyAction(keyCode: 49, modifiers: .command, isRecording: false) == .passThrough)
}

@Test @MainActor func layoutSpacingControlsUpdateTheGridImmediately() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("launchpad-settings-layout-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = GridModel(layoutStore: LayoutStore(directory: directory))
    let viewModel = SettingsViewModel(
        model: model,
        onTriggerSettingsChanged: { _ in .failed },
        onDockVisibilityChanged: { _ in }
    )

    viewModel.horizontalSpacing = 18
    viewModel.verticalSpacing = 36
    viewModel.pageMargins = 54

    #expect(model.gridSettings.horizontalSpacing == 18)
    #expect(model.gridSettings.verticalSpacing == 36)
    #expect(model.gridSettings.pageMargins == 54)
}

@Test @MainActor func resetGridLayoutRestoresGeometryWithoutChangingSortMode() {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("launchpad-settings-reset-test-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = GridModel(layoutStore: LayoutStore(directory: directory))
    var custom = model.gridSettings
    custom.columns = 4
    custom.rows = 3
    custom.horizontalSpacing = 52
    custom.verticalSpacing = 48
    custom.pageMargins = 72
    custom.iconScale = 1.18
    custom.sortMode = .lastUsed
    custom.labelVisible = false
    model.updateGridSettings(custom)

    let viewModel = SettingsViewModel(
        model: model,
        onTriggerSettingsChanged: { _ in .failed },
        onDockVisibilityChanged: { _ in }
    )
    viewModel.resetGridLayout()

    #expect(model.gridSettings.columns == GridSettings.default.columns)
    #expect(model.gridSettings.rows == GridSettings.default.rows)
    #expect(model.gridSettings.horizontalSpacing == GridSettings.default.horizontalSpacing)
    #expect(model.gridSettings.verticalSpacing == GridSettings.default.verticalSpacing)
    #expect(model.gridSettings.pageMargins == GridSettings.default.pageMargins)
    #expect(model.gridSettings.iconScale == GridSettings.default.iconScale)
    #expect(model.gridSettings.sortMode == .lastUsed)
    #expect(!model.gridSettings.labelVisible)
    #expect(!viewModel.labelVisible)
}

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

    await waitUntil { callbackCount > 0 && viewModel.f4Enabled == previous.f4Enabled }

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
    await waitUntil { refreshEntered }
    #expect(refreshEntered)

    viewModel.f4Enabled = !previous.f4Enabled
    releaseRefresh = true
    await waitUntil { callbackCount == 2 }

    #expect(callbackCount == 2)
    #expect(model.triggerSettings == previous)
}

/// Showing the window again refreshes the controls from the model. While an edit
/// is still being applied, the model is the older value: reading it back dropped
/// the edit queued behind the one in flight.
@Test @MainActor func refreshLeavesATriggerEditThatIsStillBeingApplied() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("launchpad-settings-refresh-pending-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = GridModel(layoutStore: LayoutStore(directory: directory))
    let previous = model.triggerSettings
    var applied: [TriggerSettings] = []
    var releaseFirst = false
    let viewModel = SettingsViewModel(
        model: model,
        onTriggerSettingsChanged: { settings in
            applied.append(settings)
            if applied.count == 1 {
                while !releaseFirst { await Task.yield() }
            }
            return TriggerSettingsApplyResult(
                f4Active: false, multitouchActive: false, multitouchEventArbitrationActive: false,
                gestureConflictStatus: .unchanged, gestureConflictBackup: nil
            )
        },
        onDockVisibilityChanged: { _ in }
    )

    viewModel.f4Enabled = !previous.f4Enabled
    await waitUntil { !applied.isEmpty }
    #expect(applied.count == 1)

    viewModel.hotkeyEnabled = !previous.hotkeyEnabled
    viewModel.refresh()
    #expect(viewModel.hotkeyEnabled == !previous.hotkeyEnabled, "refresh overwrote an edit that had not been applied yet")

    releaseFirst = true
    await waitUntil { applied.last?.hotkeyEnabled == !previous.hotkeyEnabled }
    #expect(applied.last?.hotkeyEnabled == !previous.hotkeyEnabled, "the queued edit never reached the apply callback")
    #expect(viewModel.hotkeyEnabled == !previous.hotkeyEnabled)
}

/// A combination another app already holds registers nothing and says nothing; the
/// result has to carry that to the window, or the toggle just looks switched on.
@Test @MainActor func aHotkeyThatCouldNotBeRegisteredIsReportedToTheWindow() async {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("launchpad-settings-hotkey-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let model = GridModel(layoutStore: LayoutStore(directory: directory))
    let viewModel = SettingsViewModel(
        model: model,
        onTriggerSettingsChanged: { _ in
            TriggerSettingsApplyResult(
                f4Active: false, hotkeyActive: false, multitouchActive: false, multitouchEventArbitrationActive: false,
                gestureConflictStatus: .unchanged, gestureConflictBackup: nil
            )
        },
        onDockVisibilityChanged: { _ in }
    )
    #expect(viewModel.hotkeyActive)

    viewModel.hotkeyEnabled = !model.triggerSettings.hotkeyEnabled
    await waitUntil { !viewModel.hotkeyActive }

    #expect(!viewModel.hotkeyActive)
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
    await waitUntil { viewModel.multitouchActive }

    #expect(viewModel.multitouchActive)
    #expect(!viewModel.multitouchEventArbitrationActive)
}
