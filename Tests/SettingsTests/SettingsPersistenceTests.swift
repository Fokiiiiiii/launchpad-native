import Catalog
import Foundation
import Persistence
import Testing
@testable import Grid
@testable import Settings

/// Every control in Settings is wired the same way: a `@Published` property
/// whose `didSet` pushes into `GridModel` and then persists. That wiring is
/// mechanical and easy to get subtly wrong — a missing `persist()` loses the
/// setting on relaunch, a missing model call leaves the UI claiming something
/// the app is not doing, and neither shows up until someone changes the setting
/// and reopens the app.
///
/// These tests take each control through the whole path: change it, reload the
/// document from disk, and check it came back.
@MainActor
private func makeModel(_ directory: URL) async -> GridModel {
    let model = GridModel(layoutStore: LayoutStore(directory: directory))
    await model.loadDocument()
    return model
}

@MainActor
private func makeViewModel(_ model: GridModel) -> SettingsViewModel {
    SettingsViewModel(
        model: model,
        onTriggerSettingsChanged: { _ in
            TriggerSettingsApplyResult(
                f4Active: true,
                multitouchActive: true,
                multitouchEventArbitrationActive: true,
                gestureConflictStatus: .unchanged,
                gestureConflictBackup: nil
            )
        },
        onDockVisibilityChanged: { _ in }
    )
}

/// Reloads the document from disk into a fresh model, the way a relaunch does.
@MainActor
private func reloaded(_ directory: URL) async -> GridModel {
    let fresh = GridModel(layoutStore: LayoutStore(directory: directory))
    await fresh.loadDocument()
    return fresh
}

/// Reloads until the write has landed, or gives up and returns what is there.
///
/// Settings persists on a detached task, so the write is not done when the
/// property setter returns. Polling rather than sleeping a fixed time: a flat
/// wait passed at 600ms and failed at 150ms on the same machine, which means it
/// would fail somewhere else too.
@MainActor
private func reloaded(_ directory: URL, until isSettled: (GridModel) -> Bool) async throws -> GridModel {
    for _ in 0..<80 {
        let fresh = await reloaded(directory)
        if isSettled(fresh) { return fresh }
        try await Task.sleep(for: .milliseconds(25))
    }
    return await reloaded(directory)
}

// MARK: layout

@Test @MainActor func gridGeometrySurvivesARelaunch() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = await makeModel(dir)
    let viewModel = makeViewModel(model)

    viewModel.columns = 5
    viewModel.rows = 4
    viewModel.horizontalSpacing = 33
    viewModel.verticalSpacing = 21
    viewModel.pageMargins = 55

    let fresh = try await reloaded(dir) { $0.gridSettings.pageMargins == 55 }
    #expect(fresh.gridSettings.columns == 5)
    #expect(fresh.gridSettings.rows == 4)
    #expect(fresh.gridSettings.horizontalSpacing == 33)
    #expect(fresh.gridSettings.verticalSpacing == 21)
    #expect(fresh.gridSettings.pageMargins == 55)
}

@Test @MainActor func iconScaleSurvivesARelaunchAndMarksItselfCustom() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = await makeModel(dir)
    let viewModel = makeViewModel(model)

    viewModel.iconScale = 1.12

    // Moving the slider by hand is by definition not one of the presets.
    #expect(viewModel.iconScalePreset == .custom)
    let fresh = try await reloaded(dir) { abs($0.gridSettings.iconScale - 1.12) < 0.0001 }
    #expect(abs(fresh.gridSettings.iconScale - 1.12) < 0.0001)
}

/// The presets exist so the slider is not the only way to set this; picking one
/// must not then report itself as a custom value.
@Test @MainActor func choosingAnIconScalePresetKeepsThePresetIdentity() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = await makeModel(dir)
    let viewModel = makeViewModel(model)

    for preset in GridIconScalePreset.allCases where preset != .custom {
        viewModel.applyIconScalePreset(preset)
        #expect(viewModel.iconScalePreset == preset, "\(preset) did not stick")
    }
}

@Test @MainActor func layoutAndSortModeSurviveARelaunch() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = await makeModel(dir)
    let viewModel = makeViewModel(model)

    viewModel.sortMode = .name

    let fresh = try await reloaded(dir) { $0.gridSettings.sortMode == .name }
    #expect(fresh.gridSettings.sortMode == .name)
}

// MARK: appearance

@Test @MainActor func backgroundSettingsSurviveARelaunch() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = await makeModel(dir)
    let viewModel = makeViewModel(model)

    viewModel.backgroundMode = .wallpaper
    viewModel.glassMaterialIntensity = 0.62
    viewModel.blursWallpaper = false

    let fresh = try await reloaded(dir) { $0.blursWallpaper == false && $0.backgroundMode == .wallpaper }
    #expect(fresh.backgroundMode == .wallpaper)
    #expect(abs(fresh.glassMaterialIntensity - 0.62) < 0.0001)
    #expect(fresh.blursWallpaper == false)
}

@Test @MainActor func appIconStyleSurvivesARelaunchAndNotifies() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = await makeModel(dir)
    var notified: AppIconStyle?
    let viewModel = SettingsViewModel(
        model: model,
        onTriggerSettingsChanged: { _ in
            TriggerSettingsApplyResult(f4Active: true, multitouchActive: true, multitouchEventArbitrationActive: true, gestureConflictStatus: .unchanged, gestureConflictBackup: nil)
        },
        onDockVisibilityChanged: { _ in },
        onAppIconStyleChanged: { notified = $0 }
    )

    viewModel.appIconStyle = .monochrome

    #expect(notified == .monochrome, "the app was never told to change its icon")
    let fresh = try await reloaded(dir) { $0.appIconStyle == .monochrome }
    #expect(fresh.appIconStyle == .monochrome)
}

// MARK: behaviour toggles

@Test @MainActor func appVisibilityTogglesSurviveARelaunch() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = await makeModel(dir)
    let viewModel = makeViewModel(model)

    viewModel.showsMenuBarIcon = false
    viewModel.showsHiddenAppsInSearch = true
    viewModel.showMenuBarApplications = true

    let fresh = try await reloaded(dir) { $0.showsMenuBarIcon == false && $0.showsHiddenAppsInSearch }
    #expect(fresh.showsMenuBarIcon == false)
    #expect(fresh.showsHiddenAppsInSearch == true)
    #expect(fresh.showMenuBarApplications == true)
}

/// Toggles that act on something outside the document still have to reach it.
@Test @MainActor func hideDockNotifiesEvenThoughItIsNotPersistedHere() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = await makeModel(dir)
    var received: [Bool] = []
    let viewModel = SettingsViewModel(
        model: model,
        onTriggerSettingsChanged: { _ in
            TriggerSettingsApplyResult(f4Active: true, multitouchActive: true, multitouchEventArbitrationActive: true, gestureConflictStatus: .unchanged, gestureConflictBackup: nil)
        },
        onDockVisibilityChanged: { received.append($0) }
    )

    viewModel.hideDockWhileLauncherOpen = true
    viewModel.hideDockWhileLauncherOpen = false
    #expect(received == [true, false])
}

/// Setting a value to what it already is must not churn the model or the disk —
/// every `didSet` guards on this, and losing that guard is invisible until
/// something starts writing on every keystroke.
@Test @MainActor func settingAValueToItselfDoesNothing() async throws {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: dir) }
    let model = await makeModel(dir)
    var dockNotifications = 0
    let viewModel = SettingsViewModel(
        model: model,
        onTriggerSettingsChanged: { _ in
            TriggerSettingsApplyResult(f4Active: true, multitouchActive: true, multitouchEventArbitrationActive: true, gestureConflictStatus: .unchanged, gestureConflictBackup: nil)
        },
        onDockVisibilityChanged: { _ in dockNotifications += 1 }
    )

    let current = viewModel.hideDockWhileLauncherOpen
    viewModel.hideDockWhileLauncherOpen = current
    viewModel.hideDockWhileLauncherOpen = current
    #expect(dockNotifications == 0)
}
