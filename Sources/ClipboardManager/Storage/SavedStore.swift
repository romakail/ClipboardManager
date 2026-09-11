import Foundation

private struct SavedEnvelope: Codable {
    var schemaVersion: Int
    var items: [ClipboardItem]
}

/// Items the user has explicitly chosen to keep, separate from the rolling capture history.
/// Unlike HistoryStore there's no capture/eviction logic — items only arrive via `save(_:)`.
final class SavedStore {
    /// Newest first.
    private(set) var items: [ClipboardItem] = []

    /// Fired on the main thread whenever `items` actually changes.
    var onChange: (() -> Void)?

    private let saveQueue = DispatchQueue(label: "com.local.ClipboardManager.savedStoreSave")
    private var saveWorkItem: DispatchWorkItem?

    init() {
        load()
    }

    /// Returns true if a new entry was added (false if it was a no-op duplicate-of-top).
    @discardableResult
    func save(_ item: ClipboardItem) -> Bool {
        // Already saved elsewhere in the list: just bring it back to the top rather than duplicating.
        if let existingIndex = items.firstIndex(where: { $0.contentHash == item.contentHash }) {
            let existing = items.remove(at: existingIndex)
            items.insert(existing, at: 0)
            scheduleSave()
            onChange?()
            return false
        }

        var imageFileName = item.imageFileName
        if item.type == .image {
            guard let original = item.imageFileName, let duplicated = ImageStore.duplicate(fileName: original) else { return false }
            imageFileName = duplicated
        }

        let saved = ClipboardItem(
            id: UUID(),
            type: item.type,
            timestamp: Date(),
            textContent: item.textContent,
            rtfData: item.rtfData,
            htmlData: item.htmlData,
            imageFileName: imageFileName,
            contentHash: item.contentHash,
            sourceAppBundleID: item.sourceAppBundleID
        )
        items.insert(saved, at: 0)
        scheduleSave()
        onChange?()
        return true
    }

    func remove(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        let removed = items.remove(at: index)
        if removed.type == .image, let fileName = removed.imageFileName {
            ImageStore.delete(fileName: fileName)
        }
        scheduleSave()
        onChange?()
    }

    func moveToTop(id: UUID) {
        guard let index = items.firstIndex(where: { $0.id == id }), index != 0 else { return }
        let item = items.remove(at: index)
        items.insert(item, at: 0)
        scheduleSave()
        onChange?()
    }

    /// User-driven manual reorder (drag and drop).
    func moveItem(id: UUID, toIndex targetIndex: Int) {
        guard let currentIndex = items.firstIndex(where: { $0.id == id }), currentIndex != targetIndex else { return }
        let item = items.remove(at: currentIndex)
        items.insert(item, at: min(max(targetIndex, 0), items.count))
        scheduleSave()
        onChange?()
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
        let envelope = SavedEnvelope(schemaVersion: 1, items: items)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        guard let data = try? encoder.encode(envelope) else { return }
        try? data.write(to: AppPaths.savedFile, options: .atomic)
    }

    private func load() {
        guard let data = try? Data(contentsOf: AppPaths.savedFile) else { return }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let envelope = try? decoder.decode(SavedEnvelope.self, from: data) else { return }
        items = envelope.items
    }
}
