import AppKit

/// Sits behind the search field and grid. A click that lands here (i.e. not
/// on any child control, which would intercept the mouseDown itself) means
/// the user clicked the launcher's empty background — dismiss.
final class BackgroundClickCatcherView: NSView {
    var onBackgroundClick: (() -> Void)?

    override func mouseDown(with event: NSEvent) {
        onBackgroundClick?()
    }
}
