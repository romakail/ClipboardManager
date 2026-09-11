import AppKit

/// The second, "saved" row: a thin header plus a horizontal strip of previously-saved items,
/// reusing the same card view as the main history row. Composed into HistoryPanelController the
/// same way ImagePreviewController is — a self-contained sub-controller with its own selection.
final class SavedRowController: NSObject {
    static let rowHeight: CGFloat = 22 + HistoryItemView.cardSize.height + 16 // header + card + section insets

    let view = NSView()
    private let store: SavedStore
    private let headerView = NSView()
    private let headerLabel = NSTextField(labelWithString: "Saved")
    private let emptyLabel = NSTextField(labelWithString: "No saved items yet — ⌘S on a history item")
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()

    private(set) var selectedIndex = 0
    var items: [ClipboardItem] { store.items }

    /// Fired when the user clicks a card directly (mouse path) — the owner decides what "activate" means.
    var onCardActivated: (() -> Void)?

    private static let headerColor = NSColor(srgbRed: 0.62, green: 0.80, blue: 0.86, alpha: 1.0)
    private static let reorderPasteboardType = NSPasteboard.PasteboardType("com.local.ClipboardManager.savedReorder")
    /// See HistoryPanelController's identical setup: didSelectItemsAt fires on mouse-down, before
    /// AppKit knows whether the gesture is a click or the start of a drag, so activation is
    /// deferred and cancelled if a real drag begins.
    private static let clickActivationDelay: TimeInterval = 0.15
    private var pendingClickActivation: DispatchWorkItem?
    /// The item being dragged to reorder — see HistoryPanelController for the full rationale: its
    /// cell is hidden (a gap) and the model reorders live so neighbours animate aside.
    private var draggedItemID: UUID?

    init(store: SavedStore) {
        self.store = store
        super.init()
        setupViews()
    }

    private func setupViews() {
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = Self.headerColor.cgColor
        headerView.layer?.cornerRadius = 8
        headerView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerView)

        headerLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        headerLabel.textColor = .black
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(headerLabel)

        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = HistoryItemView.cardSize
        layout.minimumInteritemSpacing = 8
        layout.minimumLineSpacing = 8
        layout.sectionInset = NSEdgeInsets(top: 8, left: 12, bottom: 8, right: 12)
        collectionView.collectionViewLayout = layout
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.backgroundColors = [.clear]
        collectionView.isSelectable = true
        collectionView.register(HistoryItemView.self, forItemWithIdentifier: HistoryItemView.identifier)
        collectionView.registerForDraggedTypes([Self.reorderPasteboardType])
        collectionView.setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = collectionView
        scrollView.hasHorizontalScroller = true
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = true
        scrollView.backgroundColor = .white
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            headerView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 8),
            headerView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -8),
            headerView.topAnchor.constraint(equalTo: view.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: 22),

            headerLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 10),
            headerLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 6),
            scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
        ])
    }

    // MARK: - Data / selection

    func reload() {
        collectionView.reloadData()
        emptyLabel.isHidden = !items.isEmpty
        clampSelection()
    }

    private func clampSelection() {
        selectedIndex = min(selectedIndex, max(items.count - 1, 0))
    }

    func resetSelection() {
        selectedIndex = 0
    }

    @discardableResult
    func moveSelection(by delta: Int) -> Bool {
        let count = items.count
        guard count > 0 else { return false }
        let newIndex = max(0, min(count - 1, selectedIndex + delta))
        guard newIndex != selectedIndex else { return false }
        selectedIndex = newIndex
        collectionView.reloadData()
        scrollToSelection()
        return true
    }

    func scrollToSelection() {
        guard selectedIndex < items.count else { return }
        collectionView.scrollToItems(at: [IndexPath(item: selectedIndex, section: 0)], scrollPosition: .centeredHorizontally)
    }

    func selectedItem() -> ClipboardItem? {
        guard selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    func removeSelected() {
        guard let item = selectedItem() else { return }
        store.remove(id: item.id)
        reload()
    }

    /// Reloads and plays the insertion pulse on the card that just landed at the top.
    func reloadAndPulseTop() {
        reload()
        guard !items.isEmpty, let cell = collectionView.item(at: IndexPath(item: 0, section: 0)) as? HistoryItemView else { return }
        cell.playInsertionAnimation()
    }
}

// MARK: - NSCollectionViewDataSource / Delegate

extension SavedRowController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        items.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let cell = collectionView.makeItem(withIdentifier: HistoryItemView.identifier, for: indexPath) as? HistoryItemView else {
            return NSCollectionViewItem()
        }
        if indexPath.item < items.count {
            let item = items[indexPath.item]
            cell.configure(with: item, highlighted: indexPath.item == selectedIndex)
            cell.view.isHidden = item.id == draggedItemID // the dragged item's slot shows as a gap
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        selectedIndex = indexPath.item
        pendingClickActivation?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.onCardActivated?() }
        pendingClickActivation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clickActivationDelay, execute: work)
    }

    func collectionView(
        _ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>
    ) {
        pendingClickActivation?.cancel()
        pendingClickActivation = nil
        guard let index = indexPaths.first?.item, index < items.count else { return }
        draggedItemID = items[index].id
        collectionView.item(at: IndexPath(item: index, section: 0))?.view.isHidden = true
    }

    func collectionView(
        _ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation
    ) {
        clearDragState()
    }

    /// Un-hides the dragged item's cell and forgets it. Safe to call twice.
    private func clearDragState() {
        guard let id = draggedItemID else { return }
        draggedItemID = nil
        if let index = items.firstIndex(where: { $0.id == id }) {
            collectionView.item(at: IndexPath(item: index, section: 0))?.view.isHidden = false
        }
    }

    // MARK: - Drag to reorder

    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(indexPath.item), forType: Self.reorderPasteboardType)
        return pasteboardItem
    }

    func collectionView(
        _ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard let draggedItemID, let currentIndex = items.firstIndex(where: { $0.id == draggedItemID }) else { return [] }
        proposedDropOperation.pointee = .before

        let proposed = min(max(proposedDropIndexPath.pointee.item, 0), items.count)
        let destination = min(proposed > currentIndex ? proposed - 1 : proposed, items.count - 1)
        if destination != currentIndex {
            store.moveItem(id: draggedItemID, toIndex: destination) // mutates store.items to its new order
            selectedIndex = destination
            collectionView.animator().performBatchUpdates({
                collectionView.moveItem(at: IndexPath(item: currentIndex, section: 0), to: IndexPath(item: destination, section: 0))
            }, completionHandler: nil)
        }
        return .move
    }

    func collectionView(
        _ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        // Live moves in validateDrop already placed the item; just settle.
        clearDragState()
        return true
    }
}
