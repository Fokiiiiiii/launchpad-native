import Foundation

/// User-facing strings shared by all targets.
public enum L10n {
    private static func string(_ key: String, _ value: String) -> String {
        LocalizationBundle.bundle.localizedString(forKey: key, value: value, table: nil)
    }

    // MARK: Settings — tabs

    public static var tabTriggers: String { string("settings.tab.triggers", "Triggers") }
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
    public static var aboutDesignCredit: String { string("settings.about.designcredit", "Designed for macOS · Liquid Glass") }

    // MARK: Settings — Grid tab

    public static func columnsLabel(_ n: Int) -> String {
        String(format: string("settings.grid.columns", "Columns: %d"), n)
    }
    public static func rowsLabel(_ n: Int) -> String {
        String(format: string("settings.grid.rows", "Rows: %d"), n)
    }
    public static func horizontalSpacingLabel(_ n: Int) -> String {
        String(format: string("settings.grid.spacing.horizontal", "Horizontal gap: %d pt"), n)
    }
    public static func verticalSpacingLabel(_ n: Int) -> String {
        String(format: string("settings.grid.spacing.vertical", "Vertical gap: %d pt"), n)
    }
    public static func pageMarginsLabel(_ n: Int) -> String {
        String(format: string("settings.grid.margins", "Page margins: %d pt"), n)
    }
    public static var resetGridLayoutButton: String { string("settings.grid.reset", "Reset Grid Layout") }
    public static var resetGridLayoutTitle: String { string("settings.grid.reset.title", "Reset grid layout?") }
    public static var resetGridLayoutMessage: String { string("settings.grid.reset.message", "Columns, rows, spacing, margins, and icon size will return to their defaults.") }
    public static var layoutModePaged: String { string("settings.grid.layout.paged", "Paged") }
    public static var sortByLabel: String { string("settings.grid.sortby", "Sort By") }
    /// Neutral section header for the group containing Sort By, Reorganize,
    /// and Hide Dock — previously reused `sortByLabel` for this header too,
    /// which read oddly once Reorganize/Hide Dock (unrelated to sorting)
    /// shared the same section.
    public static var displaySectionHeader: String { string("settings.grid.display", "Display") }
    public static var iconScalePresetCustom: String { string("settings.grid.iconscale.custom", "Custom") }
    public static var gridLayoutSectionHeader: String { string("settings.grid.layout.header", "Grid layout") }
    public static var iconScaleSectionHeader: String { string("settings.grid.iconscale.header", "Icon size") }
    public static var iconScalePresetSmart: String { string("settings.grid.iconscale.smart", "Smart") }
    public static var iconScalePresetLarge: String { string("settings.grid.iconscale.large", "Large") }
    public static var iconScalePresetStandard: String { string("settings.grid.iconscale.standard", "Standard") }
    public static var iconScalePresetCompact: String { string("settings.grid.iconscale.compact", "Compact") }
    public static var iconScaleManualLabel: String { string("settings.grid.iconscale.manual", "Manual size") }
    public static var iconScaleHint: String {
        string("settings.grid.iconscale.hint", "Smart recommends an icon size for the current grid. Manual changes use Custom.")
    }
    public static var sortModeCustom: String { string("settings.grid.sortby.custom", "Custom") }
    public static var sortModeName: String { string("settings.grid.sortby.name", "Name") }
    public static var sortModeDateAdded: String { string("settings.grid.sortby.dateadded", "Date Added") }
    public static var sortModeLastUsed: String { string("settings.grid.sortby.lastused", "Last Used") }
    public static var reorganizeButton: String { string("settings.grid.reorganize", "Reorganize") }
    public static var hideDockToggleLabel: String { string("settings.grid.hidedock", "Hide Dock") }
    public static var menuIconVisibilityLabel: String { string("settings.display.menuicons", "Menu icons") }
    public static var menuIconVisibilityAutomatic: String { string("settings.display.menuicons.automatic", "Automatic") }
    public static var menuIconVisibilityVisible: String { string("settings.display.menuicons.visible", "Show") }
    public static var menuIconVisibilityHidden: String { string("settings.display.menuicons.hidden", "Hide") }
    public static var menuIconVisibilityHint: String {
        string("settings.display.menuicons.hint", "Automatic follows macOS: shown on macOS 26, hidden by default from macOS 27.")
    }

    // MARK: Settings — App Icon picker

    public static var appIconLimitedEffectNotice: String {
        string(
            "settings.appicon.limitednotice",
            "This changes the running app's Dock/App Switcher and menu-bar icon only. The default LSUIElement build has no Dock icon, and the change resets when the app relaunches."
        )
    }
    public static var appIconStyleClassic: String { string("settings.appicon.style.classic", "Classic") }
    public static var appIconStyleMonochrome: String { string("settings.appicon.style.monochrome", "Monochrome") }
    public static var appIconStyleSolid: String { string("settings.appicon.style.solid", "Solid") }
    public static var appIconStyleDiagonal: String { string("settings.appicon.style.diagonal", "Diagonal") }

    public static var quickMenuAccessibilityLabel: String { string("launcher.quickmenu.accessibility", "View options") }
    public static var clearSearchAccessibilityLabel: String { string("launcher.search.clear.accessibility", "Clear search") }
    public static var openSettingsMenuItem: String { string("launcher.quickmenu.opensettings", "Open Settings…") }
    public static var closePanelAccessibilityLabel: String { string("panel.close.accessibility", "Close") }
    public static var selectedAccessibilityValue: String { string("settings.accessibility.selected", "Selected") }

    // MARK: Settings — Triggers tab

    public static var f4ToggleLabel: String { string("settings.triggers.f4", "F4 / Spotlight key") }
    public static var globalHotkeyToggleLabel: String { string("settings.triggers.globalhotkey", "Global hotkey") }
    public static var hotCornersGroupTitle: String { string("settings.triggers.hotcorners", "Hot Corners") }
    public static var hotCornerTopLeft: String { string("settings.triggers.hotcorner.topleft", "Top Left") }
    public static var hotCornerTopRight: String { string("settings.triggers.hotcorner.topright", "Top Right") }
    public static var hotCornerBottomLeft: String { string("settings.triggers.hotcorner.bottomleft", "Bottom Left") }
    public static var hotCornerBottomRight: String { string("settings.triggers.hotcorner.bottomright", "Bottom Right") }
    public static var trackpadGestureGroupTitle: String { string("settings.triggers.trackpadgesture", "Trackpad Gesture") }
    public static var multitouchToggleLabel: String { string("settings.triggers.multitouch", "Enable") }
    public static var fingerCountLabel: String { string("settings.triggers.fingercount", "Fingers") }
    public static var fingerCountFour: String { string("settings.triggers.fingercount.four", "4") }
    public static var fingerCountFive: String { string("settings.triggers.fingercount.five", "5") }
    public static var sensitivityLabel: String { string("settings.triggers.sensitivity", "Sensitivity") }
    public static var gestureSensitivityAccessibilityLabel: String { string("settings.triggers.sensitivity.accessibility", "Gesture sensitivity") }
    public static var f4PermissionHint: String { string("settings.triggers.f4hint", "F4 needs Input Monitoring permission") }
    public static var trackpadPermissionHint: String { string("settings.triggers.trackpadhint", "Trackpad gesture needs Accessibility and Input Monitoring permission") }
    public static var openPrivacySettingsButton: String { string("settings.triggers.openprivacysettings", "Open Privacy Settings…") }
    public static var searchNoResultsTitle: String { string("launcher.search.empty.title", "No Results") }
    public static var searchNoResultsMessage: String { string("launcher.search.empty.message", "Try a different app name.") }
    // MARK: Settings — Sources tab

    public static var removeButton: String { string("settings.sources.remove", "Remove") }
    public static var addFolderButton: String { string("settings.sources.addfolder", "Add Folder…") }
    public static var chooseFolderPanelMessage: String { string("settings.sources.chooseFolderPanelMessage", "Choose a folder to scan for applications") }

    // MARK: Settings — Hidden tab

    public static var noHiddenAppsMessage: String { string("settings.hidden.empty", "No hidden apps.") }
    public static var noHiddenAppsHint: String { string("settings.hidden.empty.hint", "Hide an app from its context menu to list it here.") }
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
        string("onboarding.permissions.body", "The F4/Spotlight-key and trackpad gesture need Accessibility and Input Monitoring permission. Everything else works without it.")
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
    public static var uninstallReportSaveFailedNotice: String {
        string(
            "uninstall.reportsavefailed",
            "The selected items were moved to Trash, but the operation history could not be saved."
        )
    }

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

    public static var searchPlaceholder: String { string("launcher.search.placeholder", "Search applications") }
    public static var searchAccessibilityLabel: String { string("launcher.search.accessibility", "Search applications") }

    // MARK: What's New

    // MARK: Settings — Diagnostics

    public static var diagnosticsHeader: String { string("settings.diagnostics.header", "Diagnostics") }
    public static var diagnosticsSaveReport: String { string("settings.diagnostics.savereport", "Export Logs…") }
    public static var diagnosticsSaveFailed: String { string("settings.diagnostics.savefailed", "The diagnostics report could not be saved.") }

    public static var whatsNewTitle: String { string("whatsnew.title", "What's New") }
    /// Deliberately not routed through the catalog: a version number reads the
    /// same in every language, and looking it up would mean a stray
    /// `whatsnew.badge` entry could replace the actual version with fixed text.
    public static func whatsNewVersionBadge(_ version: String) -> String {
        version
    }
    public static var whatsNewContinueButton: String { string("whatsnew.continue", "Continue") }
    public static var whatsNewFeatureFolderReorderTitle: String { string("whatsnew.feature.folderreorder.title", "Reorder Apps Inside Folders") }
    public static var whatsNewFeatureFolderReorderBody: String { string("whatsnew.feature.folderreorder.body", "Drag an app onto another inside an open folder to rearrange them, just like on the main grid.") }
    public static var whatsNewFeatureGestureConflictTitle: String { string("whatsnew.feature.gestureconflict.title", "Fewer Trackpad Conflicts") }
    public static var whatsNewFeatureGestureConflictBody: String { string("whatsnew.feature.gestureconflict.body", "The app can now automatically prevent macOS's own trackpad gesture from competing with the launcher's.") }
    public static var whatsNewFeatureFolderFullScreenTitle: String { string("whatsnew.feature.folderfullscreen.title", "Bigger Folder Windows") }
    public static var whatsNewFeatureFolderFullScreenBody: String { string("whatsnew.feature.folderfullscreen.body", "Opened folders now scale to the screen, so large folders have more room to breathe.") }

    // MARK: Settings — new items (Round 20)

    public static var launchAtLoginToggleLabel: String { string("settings.general.launchatlogin", "Launch at Login") }
    public static var appearanceSectionHeader: String { string("settings.general.appearance", "Appearance") }
    public static var showMenuBarIconToggleLabel: String { string("settings.general.showmenubaricon", "Show Menu Bar Icon") }
    public static var showMenuBarApplicationsToggleLabel: String { string("settings.apps.showmenubarapplications", "Show Menu Bar Applications") }
    public static var showHiddenAppsInSearchToggleLabel: String { string("settings.apps.showhiddeninsearch", "Show Hidden Apps in Search") }
    public static var backgroundSectionHeader: String { string("settings.screen.background", "Background") }
    public static var backgroundModeWallpaper: String { string("settings.screen.background.wallpaper", "Wallpaper") }
    public static var backgroundModeGlass: String { string("settings.screen.background.glass", "Glass") }
    public static var glassMaterialLabel: String { string("settings.screen.background.material", "Glass Material") }
    public static var blurWallpaperToggleLabel: String { string("settings.screen.background.blur", "Blur Wallpaper") }

    // MARK: Menu bar icon

    public static var menuBarOpenLauncherItem: String { string("menubar.openlauncher", "Open Launcher") }
    public static var menuBarQuitItem: String { string("menubar.quit", "Quit") }
}
