import AppKit
import Foundation

final class ClipboardMonitor {
    private let store: HistoryStore
    private var timer: Timer?

    /// The changeCount we've already captured into history (or started at).
    private var lastCapturedChangeCount: Int
    /// A changeCount seen but not yet acted on — only captured once it's seen unchanged on a
    /// following tick, since some apps write a pasteboard's representations in more than one step.
    private var pendingChangeCount: Int?
    /// The frontmost app when the change was first observed, closest we can get to "who copied this."
    private var pendingSourceApp: NSRunningApplication?

    init(store: HistoryStore) {
        self.store = store
        self.lastCapturedChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        timer = Timer.scheduledTimer(withTimeInterval: 0.35, repeats: true) { [weak self] _ in
            self?.pollPasteboard()
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func pollPasteboard() {
        let currentChangeCount = NSPasteboard.general.changeCount
        guard currentChangeCount != lastCapturedChangeCount else {
            pendingChangeCount = nil
            pendingSourceApp = nil
            return
        }

        guard currentChangeCount == pendingChangeCount else {
            // First time we've seen this changeCount — capture whoever's frontmost right now
            // (closest we'll get to "who actually copied this"), then wait one more tick to let
            // any additional pasteboard writes from the same copy settle before capturing.
            pendingChangeCount = currentChangeCount
            pendingSourceApp = NSWorkspace.shared.frontmostApplication
            return
        }

        pendingChangeCount = nil
        lastCapturedChangeCount = currentChangeCount
        let sourceApp = pendingSourceApp
        pendingSourceApp = nil
        capture(from: NSPasteboard.general, sourceApp: sourceApp)
    }

    private func capture(from pasteboard: NSPasteboard, sourceApp: NSRunningApplication?) {
        var bundleID = sourceApp?.bundleIdentifier
        if bundleID == Bundle.main.bundleIdentifier { bundleID = nil } // never attribute to ourselves

        if let image = readImage(from: pasteboard) {
            store.recordCapture(type: .image, textContent: nil, image: image, sourceAppBundleID: bundleID)
            return
        }

        if let string = pasteboard.string(forType: .string), !string.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let type: ClipboardItemType = URLDetector.isWholeStringURL(string) ? .url : .text
            store.recordCapture(type: type, textContent: string, image: nil, sourceAppBundleID: bundleID)
        }
    }

    private func readImage(from pasteboard: NSPasteboard) -> NSImage? {
        // Only treat it as an image capture if there's no plain string alongside it that we'd rather store,
        // and an actual image type is present.
        let imageTypes: [NSPasteboard.PasteboardType] = [.png, .tiff]
        guard pasteboard.types?.contains(where: { imageTypes.contains($0) }) == true else { return nil }
        guard pasteboard.string(forType: .string) == nil else { return nil }

        if let data = pasteboard.data(forType: .png), let image = NSImage(data: data) {
            return image
        }
        if let data = pasteboard.data(forType: .tiff), let image = NSImage(data: data) {
            return image
        }
        return nil
    }
}
