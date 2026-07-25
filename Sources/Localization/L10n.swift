import Foundation

/// All user-facing strings across the app, routed through this one
/// namespace so every target shares one `Localizable.xcstrings` catalog
/// instead of duplicating resource bundles per target. Uses the classic
/// `Bundle.localizedString(forKey:value:table:)` lookup (not the newer
/// string-interpolation-based `String(localized:)` key auto-generation)
/// deliberately — that API's key is whatever the compiler derives from the
/// interpolated literal, which is easy to get subtly wrong when hand-
/// authoring the `.xcstrings` file's keys to match. An explicit key we
/// choose ourselves, with the English text as the `value` fallback, is
/// unambiguous in both directions.
public enum L10n {
    private static func string(_ key: String, _ value: String) -> String {
        LocalizationBundle.bundle.localizedString(forKey: key, value: value, table: nil)
    }

    // MARK: Settings — tabs

    public static var tabGrid: String { string("settings.tab.grid", "Grid") }
    public static var tabTriggers: String { string("settings.tab.triggers", "Triggers") }
    public static var tabSources: String { string("settings.tab.sources", "Sources") }
    public static var tabHidden: String { string("settings.tab.hidden", "Hidden Apps") }
    public static var tabUninstall: String { string("settings.tab.uninstall", "Uninstall") }

    // MARK: Settings — Grid tab

    public static func columnsLabel(_ n: Int) -> String {
        String(format: string("settings.grid.columns", "Columns: %d"), n)
    }
    public static func rowsLabel(_ n: Int) -> String {
        String(format: string("settings.grid.rows", "Rows: %d"), n)
    }
    public static func iconSizeLabel(_ n: Int) -> String {
        String(format: string("settings.grid.iconsize", "Icon size: %dpt"), n)
    }
    public static var iconSizeAccessibilityLabel: String { string("settings.grid.iconsize.accessibility", "Icon size") }
    public static var layoutPickerLabel: String { string("settings.grid.layout", "Layout") }
    public static var layoutModePaged: String { string("settings.grid.layout.paged", "Paged") }
    public static var layoutModeVerticalScroll: String { string("settings.grid.layout.verticalscroll", "Vertical Scroll") }
    public static var applyButton: String { string("settings.apply", "Apply") }

    // MARK: Settings — Triggers tab

    public static var f4ToggleLabel: String { string("settings.triggers.f4", "F4 / Spotlight key") }
    public static var globalHotkeyToggleLabel: String { string("settings.triggers.globalhotkey", "Global hotkey") }
    public static var hotCornersGroupTitle: String { string("settings.triggers.hotcorners", "Hot Corners") }
    public static var hotCornerTopLeft: String { string("settings.triggers.hotcorner.topleft", "Top Left") }
    public static var hotCornerTopRight: String { string("settings.triggers.hotcorner.topright", "Top Right") }
    public static var hotCornerBottomLeft: String { string("settings.triggers.hotcorner.bottomleft", "Bottom Left") }
    public static var hotCornerBottomRight: String { string("settings.triggers.hotcorner.bottomright", "Bottom Right") }
    public static var trackpadGestureGroupTitle: String { string("settings.triggers.trackpadgesture", "Trackpad Gesture") }
    public static var multitouchToggleLabel: String { string("settings.triggers.multitouch", "3-finger pinch to open, spread to close") }
    public static var sensitivityLabel: String { string("settings.triggers.sensitivity", "Sensitivity") }
    public static var gestureSensitivityAccessibilityLabel: String { string("settings.triggers.sensitivity.accessibility", "Gesture sensitivity") }
    public static var f4PermissionHint: String { string("settings.triggers.f4hint", "F4 needs Input Monitoring permission") }
    public static var openPrivacySettingsButton: String { string("settings.triggers.openprivacysettings", "Open Privacy Settings…") }
    public static var gestureConflictHint: String {
        string(
            "settings.triggers.gestureconflicthint",
            "This gesture may conflict with macOS's own Launchpad/Mission Control trackpad gestures. If it feels unreliable, open Trackpad settings and disable the matching system gesture."
        )
    }
    public static var openTrackpadSettingsButton: String { string("settings.triggers.opentrackpadsettings", "Open Trackpad Settings…") }

    // MARK: Settings — Sources tab

    public static var removeButton: String { string("settings.sources.remove", "Remove") }
    public static var addFolderButton: String { string("settings.sources.addfolder", "Add Folder…") }
    public static var chooseFolderPanelMessage: String { string("settings.sources.chooseFolderPanelMessage", "Choose a folder to scan for applications") }

    // MARK: Settings — Hidden tab

    public static var noHiddenAppsMessage: String { string("settings.hidden.empty", "No hidden apps.") }
    public static var unhideButton: String { string("settings.hidden.unhide", "Unhide") }

    // MARK: Settings — Uninstall tab

    public static var uninstallSelectPrompt: String { string("settings.uninstall.selectprompt", "Select an app to see what would be removed.") }
    public static var uninstallNoItemsFound: String { string("settings.uninstall.noitemsfound", "No related files or registrations were found for this app.") }
    public static var uninstallPreviewNotice: String { string("settings.uninstall.previewnotice", "This is a preview only — nothing is deleted or stopped yet.") }
    public static var needsHelperLabel: String { string("settings.uninstall.needshelper", "needs helper") }
    public static var saveDryRunReportButton: String { string("settings.uninstall.savedryrun", "Save Dry-Run Report") }
    public static var moveToTrashButton: String { string("settings.uninstall.movetotrash", "Move Owned Items to Trash…") }
    public static var uninstallSafetyNotice: String {
        string(
            "settings.uninstall.safetynotice",
            "Only \"owned\" items are ever removed, and always to the Trash — never a permanent delete. Shared-risk, unknown, and helper-required items are shown for visibility only and are never touched."
        )
    }
    public static func moveToTrashAlertTitle(_ count: Int) -> String {
        String(format: string("settings.uninstall.movetotrashalert.title", "Move %d item(s) to Trash?"), count)
    }
    public static var moveToTrashConfirmButton: String { string("settings.uninstall.movetotrashalert.confirm", "Move to Trash") }
    public static var cancelButton: String { string("common.cancel", "Cancel") }
    public static var classificationOwned: String { string("settings.uninstall.classification.owned", "owned") }
    public static var classificationSharedRisk: String { string("settings.uninstall.classification.sharedrisk", "shared risk") }
    public static var classificationUnknown: String { string("settings.uninstall.classification.unknown", "unknown") }

    // MARK: Settings — Hotkey recorder

    public static var hotkeyClickToRecord: String { string("settings.hotkey.clicktorecord", "Click to record") }
    public static var hotkeyPressCombo: String { string("settings.hotkey.presscombo", "Press a key combo…") }
    public static func hotkeyUnknownKey(_ code: Int) -> String {
        String(format: string("settings.hotkey.unknownkey", "Key %d"), code)
    }

    // MARK: Grid — context menu

    public static var menuOpen: String { string("menu.open", "Open") }
    public static var menuOpenNewInstance: String { string("menu.opennewinstance", "Open New Instance") }
    public static var menuShowInFinder: String { string("menu.showinfinder", "Show in Finder") }
    public static var menuAddToDock: String { string("menu.addtodock", "Add to Dock") }
    public static var menuRename: String { string("menu.rename", "Rename") }
    public static var menuHide: String { string("menu.hide", "Hide") }
    public static var menuRemoveFromFolder: String { string("menu.removefromfolder", "Remove from Folder") }
    public static var menuShowWindows: String { string("menu.showwindows", "Show Windows") }
    public static var menuUninstall: String { string("menu.uninstall", "Uninstall\u{2026}") }
    public static var menuUninstallTooltip: String { string("menu.uninstall.tooltip", "Preview what would be removed (Settings ▸ Uninstall). No files are deleted yet.") }
    public static var menuGetInfo: String { string("menu.getinfo", "Get Info") }
    public static var menuRenameFolder: String { string("menu.renamefolder", "Rename Folder") }

    // MARK: Grid — rename alert, folders

    public static var renameAlertTitle: String { string("grid.renamealert.title", "Rename") }
    public static var renameConfirmButton: String { string("grid.renamealert.confirm", "Rename") }
    public static var defaultFolderName: String { string("grid.defaultfoldername", "Folder") }

    // MARK: Grid — page control

    public static var previousPageAccessibilityLabel: String { string("grid.pagecontrol.previous", "Previous Page") }
    public static var nextPageAccessibilityLabel: String { string("grid.pagecontrol.next", "Next Page") }
    public static func pageNumberAccessibilityLabel(_ n: Int) -> String {
        String(format: string("grid.pagecontrol.pagenumber", "Page %d"), n)
    }

    // MARK: Launcher

    public static var searchPlaceholder: String { string("launcher.search.placeholder", "Search") }
    public static var searchAccessibilityLabel: String { string("launcher.search.accessibility", "Search applications") }
    public static var settingsButtonAccessibilityLabel: String { string("launcher.settingsbutton.accessibility", "Settings") }
}
