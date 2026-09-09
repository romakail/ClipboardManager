import AppKit
import Foundation

private struct HistoryEnvelope: Codable {
    var schemaVersion: Int
    var items: [ClipboardItem]
}

final class HistoryStore {
    static let maxItems = 1000

    /// Newest first.
    private(set) var items: [ClipboardItem] = []
    private var hashIndex: [String: UUID] = [:]

    /// Fired on the main thread whenever `items` actually changes (new capture, reorder, or eviction).
    var onChange: (() -> Void)?

    private let saveQueue = DispatchQueue(label: "com.local.ClipboardManager.historySave")
    private var saveWorkItem: DispatchWorkItem?

    init() {
        load()
    }

    // MARK: - Capture (new content observed on the pasteboard)

    /// Returns true if a new/updated item was actually recorded (i.e. it wasn't a no-op duplicate-of-top).
    @discardableResult
    func recordCapture(type: ClipboardItemType, textContent: String?, image: NSImage?, sourceAppBundleID: String?) -> Bool {
        let hash: String
        var imageFileName: String?

        switch type {
        case .text, .url:
            guard let textContent, !textContent.isEmpty else { return false }
            hash = ContentHasher.hash(textContent)
        case .image:
            guard let image else { return false }
            guard let saved = ImageStore.save(image) else { return false }
            hash = ContentHasher.hash(saved.pngData)
            imageFileName = saved.fileName
        }

        // Ignore if identical to the current top item (covers re-captures of our own pasteboard writes).
        if let top = items.first, top.contentHash == hash {
            if type == .image, let imageFileName { ImageStore.delete(fileName: imageFileName) }
            return false
        }

        // If this content already exists elsewhere in history, remove the old entry (it will be re-inserted fresh).
        if let existingID = hashIndex[hash], let existingIndex = items.firstIndex(where: { $0.id == existingID }) {
            let old = items.remove(at: existingIndex)
            if type == .image, let imageFileName {
                // We just saved a new copy of the same bytes; discard the duplicate file and reuse the old one.
                ImageStore.delete(fileName: imageFileName)
                items.insert(makeItem(type: type, textContent: textContent, imageFileName: old.imageFileName, hash: hash, sourceAppBundleID: sourceAppBundleID), at: 0)
            } else {
                items.insert(makeItem(type: type, textContent: textContent, imageFileName: old.imageFileName, hash: hash, sourceAppBundleID: sourceAppBundleID), at: 0)
            }
        } else {
            items.insert(makeItem(type: type, textContent: textContent, imageFileName: imageFileName, hash: hash, sourceAppBundleID: sourceAppBundleID), at: 0)
        }

        rebuildHashIndex()
        evictIfNeeded()
        scheduleSave()
        onChange?()
        return true
    }

    private func makeItem(type: ClipboardItemType, textContent: String?, imageFileName: String?, hash: String, sourceAppBundleID: String?) -> ClipboardItem {
        ClipboardItem(id: UUID(), type: type, timestamp: Date(), textContent: textContent, imageFileName: imageFileName, contentHash: hash, sourceAppBundleID: sourceAppBundleID)
    }

    // MARK: - Selection (reorder to top without changing timestamp)

    func moveToTop(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index != 0 else { return }
        let item = items.remove(at: index)
        items.insert(item, at: 0)
        rebuildHashIndex()
        scheduleSave()
        onChange?()
    }

    // MARK: - Eviction

    private func evictIfNeeded() {
        guard items.count > Self.maxItems else { return }
        let overflow = items.suffix(items.count - Self.maxItems)
        for item in overflow where item.type == .image {
            if let fileName = item.imageFileName {
                ImageStore.delete(fileName: fileName)
            }
        }
        items.removeLast(items.count - Self.maxItems)
        rebuildHashIndex()
    }

    private func rebuildHashIndex() {
        hashIndex.removeAll(keepingCapacity: true)
        for item in items {
            hashIndex[item.contentHash] = item.id
        }
    }

    // MARK: - Persistence

    private func scheduleSave() {
        saveWorkItem?.cancel()
        let snapshot = items
        let work = DispatchWorkItem { [weak self] in
            self?.write(snapshot)
        }
        saveWorkItem = work
        saveQueue.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    private func write(_ items: [ClipboardItem]) {
        let envelope = HistoryEnvelope(schemaVersion: 1, items: items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope) else { return }
        try? data.write(to: AppPaths.historyFile, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.historyFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(HistoryEnvelope.self, from: data) else { return }
        items = envelope.items
        rebuildHashIndex()
    }
}
