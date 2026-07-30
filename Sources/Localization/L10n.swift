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
    public static var tabAbout: String { string("settings.tab.about", "About") }
    public static var tabGeneral: String { string("settings.tab.general", "General") }
    public static var tabScreen: String { string("settings.tab.screen", "Screen") }
    public static var tabApps: String { string("settings.tab.apps", "Apps") }
    public static var tabAdvanced: String { string("settings.tab.advanced", "Advanced") }

    // MARK: Settings — About tab

    public static func aboutVersionLabel(_ version: String, _ build: String) -> String {
        String(format: string("settings.about.version", "Version %@ (%@)"), version, build)
    }
    public static var aboutLicenseLabel: String { string("settings.about.license", "Released under the MIT License.") }
    public static var aboutOpenSourceLabel: String { string("settings.about.opensource", "Open source, no third-party dependencies.") }

    // MARK: Settings — Grid tab

    public static func columnsLabel(_ n: Int) -> String {
        String(format: string("settings.grid.columns", "Columns: %d"), n)
    }
    public static func rowsLabel(_ n: Int) -> String {
        String(format: string("settings.grid.rows", "Rows: %d"), n)
    }
    public static var layoutPickerLabel: String { string("settings.grid.layout", "Layout") }
    public static var layoutModePaged: String { string("settings.grid.layout.paged", "Paged") }
    public static var layoutModeVerticalScroll: String { string("settings.grid.layout.verticalscroll", "Vertical Scroll") }
    public static var sortByLabel: String { string("settings.grid.sortby", "Sort By") }
    /// Neutral section header for the group containing Sort By, Reorganize,
    /// and Hide Dock — previously reused `sortByLabel` for this header too,
    /// which read oddly once Reorganize/Hide Dock (unrelated to sorting)
    /// shared the same section.
    public static var displaySectionHeader: String { string("settings.grid.display", "Display") }
    public static var sortModeCustom: String { string("settings.grid.sortby.custom", "Custom") }
    public static var sortModeName: String { string("settings.grid.sortby.name", "Name") }
    public static var sortModeDateAdded: String { string("settings.grid.sortby.dateadded", "Date Added") }
    public static var sortModeLastUsed: String { string("settings.grid.sortby.lastused", "Last Used") }
    public static var reorganizeButton: String { string("settings.grid.reorganize", "Reorganize") }
    public static var hideDockToggleLabel: String { string("settings.grid.hidedock", "Hide Dock") }

    // MARK: Settings — App Icon picker

    public static var appIconSectionHeader: String { string("settings.appicon.header", "App Icon") }
    public static var appIconLimitedEffectNotice: String {
        string(
            "settings.appicon.limitednotice",
            "This app runs without a Dock icon by default — the new icon mainly shows here, in Finder, and in Get Info, unless you keep it pinned to the Dock."
        )
    }
    public static var appIconStyleClassic: String { string("settings.appicon.style.classic", "Classic") }
    public static var appIconStyleMonochrome: String { string("settings.appicon.style.monochrome", "Monochrome") }
    public static var appIconStyleSolid: String { string("settings.appicon.style.solid", "Solid") }
    public static var appIconStyleDiagonal: String { string("settings.appicon.style.diagonal", "Diagonal") }

    public static var quickMenuAccessibilityLabel: String { string("launcher.quickmenu.accessibility", "View options") }
    public static var openSettingsMenuItem: String { string("launcher.quickmenu.opensettings", "Open Settings…") }
    public static var closePanelAccessibilityLabel: String { string("panel.close.accessibility", "Close") }

    // MARK: Settings — Triggers tab

    public static var f4ToggleLabel: String { string("settings.triggers.f4", "F4 / Spotlight key") }
    public static var globalHotkeyToggleLabel: String { string("settings.triggers.globalhotkey", "Global hotkey") }
    public static var hotCornersGroupTitle: String { string("settings.triggers.hotcorners", "Hot Corners") }
    public static var hotCornerTopLeft: String { string("settings.triggers.hotcorner.topleft", "Top Left") }
    public static var hotCornerTopRight: String { string("settings.triggers.hotcorner.topright", "Top Right") }
    public static var hotCornerBottomLeft: String { string("settings.triggers.hotcorner.bottomleft", "Bottom Left") }
    public static var hotCornerBottomRight: String { string("settings.triggers.hotcorner.bottomright", "Bottom Right") }
    public static var trackpadGestureGroupTitle: String { string("settings.triggers.trackpadgesture", "Trackpad Gesture") }
    public static var multitouchToggleLabel: String { string("settings.triggers.multitouch", "Pinch to open, spread to close") }
    public static var fingerCountLabel: String { string("settings.triggers.fingercount", "Fingers") }
    public static var fingerCountFour: String { string("settings.triggers.fingercount.four", "4") }
    public static var fingerCountFive: String { string("settings.triggers.fingercount.five", "5") }
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
    public static var gestureConflictPreventionToggleLabel: String { string("settings.triggers.gestureconflictpreventiontoggle", "Auto-disable macOS's conflicting gesture") }
    public static var gestureConflictPreventionActiveHint: String {
        string(
            "settings.triggers.gestureconflictpreventionactivehint",
            "LaunchpadNative has told macOS to turn off its matching pinch gesture. A logout (or restart) may be required before this fully takes effect — you can still check System Settings › Trackpad to confirm."
        )
    }

    // MARK: Settings — Sources tab

    public static var removeButton: String { string("settings.sources.remove", "Remove") }
    public static var addFolderButton: String { string("settings.sources.addfolder", "Add Folder…") }
    public static var chooseFolderPanelMessage: String { string("settings.sources.chooseFolderPanelMessage", "Choose a folder to scan for applications") }

    // MARK: Settings — Hidden tab

    public static var noHiddenAppsMessage: String { string("settings.hidden.empty", "No hidden apps.") }
    public static var unhideButton: String { string("settings.hidden.unhide", "Unhide") }

    // MARK: Onboarding

    public static var onboardingWelcomeTitle: String { string("onboarding.welcome.title", "Welcome to LaunchpadNative") }
    public static var onboardingWelcomeSubtitle: String {
        string("onboarding.welcome.subtitle", "A fast, native app launcher for your Mac — no account, no tracking, fully open source.")
    }
    public static var onboardingTriggersTitle: String { string("onboarding.triggers.title", "Three ways to open it") }
    public static var onboardingTriggersHotCorner: String { string("onboarding.triggers.hotcorner", "Hot corner — bottom right, on by default") }
    public static var onboardingTriggersHotkey: String { string("onboarding.triggers.hotkey", "F4 / Spotlight key") }
    public static var onboardingTriggersGesture: String { string("onboarding.triggers.gesture", "Trackpad pinch gesture (off by default)") }
    public static var onboardingTriggersFootnote: String {
        string("onboarding.triggers.footnote", "All of these can be changed anytime from the gear icon next to the search bar.")
    }
    public static var onboardingPermissionsTitle: String { string("onboarding.permissions.title", "One optional permission") }
    public static var onboardingPermissionsBody: String {
        string("onboarding.permissions.body", "The F4/Spotlight-key trigger needs Input Monitoring permission. Everything else works without it.")
    }
    public static var onboardingDoneTitle: String { string("onboarding.done.title", "You're all set") }
    public static var onboardingDoneBody: String {
        string("onboarding.done.body", "Open Settings anytime from the gear icon next to the search bar.")
    }
    public static var onboardingBackButton: String { string("onboarding.back", "Back") }
    public static var onboardingNextButton: String { string("onboarding.next", "Next") }
    public static var onboardingGetStartedButton: String { string("onboarding.getstarted", "Get Started") }

    public static var cancelButton: String { string("common.cancel", "Cancel") }

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
    public static var menuGetInfo: String { string("menu.getinfo", "Get Info") }
    public static var menuUninstall: String { string("menu.uninstall", "Uninstall\u{2026}") }
    public static var menuUninstallTooltip: String { string("menu.uninstall.tooltip", "Review what would be removed before anything is trashed.") }
    public static var menuRenameFolder: String { string("menu.renamefolder", "Rename Folder") }
    public static var menuUngroupFolder: String { string("menu.ungroupfolder", "Ungroup") }

    // MARK: Uninstall panel

    public static var uninstallSectionApplicationFile: String { string("uninstall.section.applicationfile", "Application File") }
    public static var uninstallSectionCache: String { string("uninstall.section.cache", "Cache") }
    public static var uninstallSectionPreferences: String { string("uninstall.section.preferences", "Preferences") }
    public static var uninstallSelectAllLabel: String { string("uninstall.selectall", "All") }
    public static var uninstallCancelButton: String { string("uninstall.cancel", "Cancel") }
    public static var uninstallMoveToTrashButton: String { string("uninstall.movetotrash", "Move to Trash") }
    public static var uninstallNeedsPermissionNotice: String { string("uninstall.needspermission", "needs admin permission — skipped") }
    public static var uninstallComputingSizesLabel: String { string("uninstall.computingsizes", "Calculating…") }

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
