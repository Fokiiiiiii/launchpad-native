import AppKit
import WindowBrowser

/// Shown in a transient popover from the "Show Windows" context menu item.
/// Enumeration/thumbnails/activation are all `WindowBrowser` (Phase 7):
/// public `ScreenCaptureKit` for both, public `NSRunningApplication` +
/// Accessibility for activation/close/minimize — no private SkyLight
/// enumeration API needed for any of this (see `WindowEnumerator`'s doc
/// comment for the one thing that would still need it: Space association).
final class WindowBrowserPopoverController: NSViewController, NSCollectionViewDataSource, NSCollectionViewDelegate {
    private let itemIdentifier = NSUserInterfaceItemIdentifier("WindowBrowserCellItem")
    private let bundleIdentifier: String
    private let thumbnailService: WindowThumbnailService
    private let onDismiss: () -> Void

    private var windows: [WindowInfo] = []
    private let collectionView = NSCollectionView()
    private let emptyLabel = NSTextField(labelWithString: "No open windows")

    init(bundleIdentifier: String, thumbnailService: WindowThumbnailService, onDismiss: @escaping () -> Void) {
        self.bundleIdentifier = bundleIdentifier
        self.thumbnailService = thumbnailService
        self.onDismiss = onDismiss
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("unavailable") }

    override func loadView() {
        let root = NSView()

        let layout = NSCollectionViewFlowLayout()
        layout.itemSize = NSSize(width: 140, height: 130)
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 8, bottom: 8, right: 8)

        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.register(WindowBrowserCellItem.self, forItemWithIdentifier: itemIdentifier)
        collectionView.backgroundColors = [.clear]

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.documentView = collectionView
        scrollView.drawsBackground = false
        scrollView.hasVerticalScroller = true

        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.isHidden = true

        root.addSubview(scrollView)
        root.addSubview(emptyLabel)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            emptyLabel.centerXAnchor.constraint(equalTo: root.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: root.centerYAnchor)
        ])
        view = root
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        Task { await loadWindows() }
    }

    private func loadWindows() async {
        windows = await WindowEnumerator.windows(forBundleIdentifier: bundleIdentifier)
        emptyLabel.isHidden = !windows.isEmpty
        collectionView.reloadData()
    }

    func numberOfSections(in collectionView: NSCollectionView) -> Int { 1 }

    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        windows.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let cell = collectionView.makeItem(withIdentifier: itemIdentifier, for: indexPath) as? WindowBrowserCellItem,
              windows.indices.contains(indexPath.item) else {
            return NSCollectionViewItem()
        }
        let window = windows[indexPath.item]
        cell.configure(title: window.title, thumbnail: nil)
        let service = thumbnailService
        Task { @MainActor in
            let thumbnail = await service.thumbnail(for: window)
            cell.configure(title: window.title, thumbnail: thumbnail)
        }
        cell.onClose = { [weak self] in self?.closeWindow(at: indexPath.item) }
        cell.onMinimize = { [weak self] in self?.minimizeWindow(at: indexPath.item) }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let index = indexPaths.first?.item, windows.indices.contains(index) else { return }
        WindowActivator.activate(windows[index])
        onDismiss()
    }

    private func closeWindow(at index: Int) {
        guard windows.indices.contains(index) else { return }
        WindowActivator.close(windows[index])
        windows.remove(at: index)
        collectionView.reloadData()
        emptyLabel.isHidden = !windows.isEmpty
    }

    private func minimizeWindow(at index: Int) {
        guard windows.indices.contains(index) else { return }
        WindowActivator.minimize(windows[index])
        onDismiss()
    }
}
