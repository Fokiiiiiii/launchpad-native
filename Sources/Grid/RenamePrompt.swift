import AppKit
import Localization

/// The modal prompt behind "Rename" — an app's alias or a folder's name.
///
/// Shared rather than duplicated: the same rename is reachable from the grid's
/// context menu and from the folder panel's, and two copies of a modal dialog
/// drift apart in exactly the ways users notice (different button order, one
/// of them not preselecting the text).
enum RenamePrompt {
    @MainActor
    static func run(currentName: String, completion: (String) -> Void) {
        let alert = NSAlert()
        alert.messageText = L10n.renameAlertTitle
        let field = NSTextField(string: currentName)
        field.frame = NSRect(x: 0, y: 0, width: 240, height: 24)
        alert.accessoryView = field
        alert.addButton(withTitle: L10n.renameConfirmButton)
        alert.addButton(withTitle: L10n.cancelButton)
        if alert.runModal() == .alertFirstButtonReturn {
            completion(field.stringValue)
        }
    }
}
