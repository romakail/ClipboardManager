import AppKit
import Quartz

/// Drives the system Quick Look panel — the exact same preview UI Finder uses for Space-to-preview.
final class ImagePreviewController: NSObject, QLPreviewPanelDataSource {
    private var currentItem: QuickLookFileItem?
    private var closeObserver: NSObjectProtocol?
    private var spaceMonitor: Any?

    /// Called when Quick Look closes itself (e.g. the user pressed Space/Esc while it was key),
    /// so the caller can restore keyboard focus to its own panel.
    var onClose: (() -> Void)?

    var isVisible: Bool {
        QLPreviewPanel.sharedPreviewPanelExists() && (QLPreviewPanel.shared()?.isVisible ?? false)
    }

    override init() {
        super.init()
        // Quick Look's own built-in "press Space again to close" isn't reliable when we're
        // driving the shared panel manually like this, so we enforce it ourselves.
        spaceMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isVisible, event.keyCode == 49 || event.keyCode == 53 else { return event } // space / escape
            self.hide()
            return nil
        }
    }

    deinit {
        if let spaceMonitor {
            NSEvent.removeMonitor(spaceMonitor)
        }
    }

    func show(fileURL: URL) {
        currentItem = QuickLookFileItem(url: fileURL)
        guard let panel = QLPreviewPanel.shared() else { return }
        panel.dataSource = self
        panel.reloadData()

        if let closeObserver {
            NotificationCenter.default.removeObserver(closeObserver)
        }
        closeObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: panel,
            queue: .main
        ) { [weak self] _ in
            self?.onClose?()
        }

        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
        panel.orderOut(nil)
        // orderOut doesn't post willCloseNotification, so restore focus ourselves rather than
        // relying solely on that observer (kept below as a fallback for any other close path).
        onClose?()
    }

    // MARK: - QLPreviewPanelDataSource

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        currentItem == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        currentItem
    }
}

final class QuickLookFileItem: NSObject, QLPreviewItem {
    private let url: URL
    init(url: URL) { self.url = url }
    var previewItemURL: URL! { url }
}
