import AppKit

/// The second, "saved" row: a thin caption plus a horizontal strip of previously-saved items,
/// reusing the same card view as the main history row. Composed into HistoryPanelController the
/// same way ImagePreviewController is — a self-contained sub-controller with its own selection.
final class SavedRowController: NSObject {
    private static let headerHeight: CGFloat = 22
    static let rowHeight: CGFloat = headerHeight + PanelMetrics.rowHeight

    let view = NSView()
    private let store: SavedStore
    private let separator = StyledView()
    private let headerIcon = NSImageView()
    private let headerLabel = NSTextField(labelWithString: "SAVED")
    private let emptyLabel = NSTextField(labelWithString: "Nothing saved yet — press ⌘S on a history item to keep it here")
    private let scrollView = HorizontalScrollView()
    private let collectionView = CardCollectionView()

    private(set) var selectedIndex = 0
    var items: [ClipboardItem] { store.items }

    /// Whether this row currently owns the keyboard; only the focused row shows a selection ring.
    var isFocused = false {
        didSet { refreshHighlights() }
    }

    /// Fired when the user clicks a card directly (mouse path) — the owner decides what "activate" means.
    var onCardActivated: (() -> Void)?
    /// Fired when a card is right-clicked (after it has become the selection); returns its menu.
    var menuProvider: (() -> NSMenu?)?

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
        separator.fillColor = .separatorColor
        separator.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(separator)

        headerIcon.image = NSImage(systemSymbolName: "pin.fill", accessibilityDescription: nil)
        headerIcon.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        headerIcon.contentTintColor = .secondaryLabelColor
        headerIcon.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerIcon)

        headerLabel.font = .systemFont(ofSize: 10.5, weight: .semibold)
        headerLabel.textColor = .secondaryLabelColor
        headerLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(headerLabel)

        collectionView.configureAsCardRow(in: scrollView, reorderType: Self.reorderPasteboardType)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.menuProvider = { [weak self] indexPath in
            guard let self else { return nil }
            self.select(index: indexPath.item)
            return self.menuProvider?()
        }
        view.addSubview(scrollView)

        emptyLabel.font = .systemFont(ofSize: 12)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(emptyLabel)

        NSLayoutConstraint.activate([
            separator.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 16),
            separator.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -16),
            separator.topAnchor.constraint(equalTo: view.topAnchor),
            separator.heightAnchor.constraint(equalToConstant: 1),

            headerIcon.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 18),
            headerIcon.centerYAnchor.constraint(equalTo: headerLabel.centerYAnchor),

            headerLabel.leadingAnchor.constraint(equalTo: headerIcon.trailingAnchor, constant: 5),
            headerLabel.topAnchor.constraint(equalTo: view.topAnchor, constant: 8),

            scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: view.topAnchor, constant: Self.headerHeight),
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
        select(index: 0)
    }

    /// Moves the selection without rebuilding the row — only the ring on the affected cards changes.
    private func select(index: Int) {
        selectedIndex = index
        clampSelection()
        refreshHighlights()
    }

    private func refreshHighlights() {
        for (index, card) in collectionView.visibleCards() {
            card.setHighlighted(isFocused && index == selectedIndex)
        }
    }

    @discardableResult
    func moveSelection(by delta: Int) -> Bool {
        let count = items.count
        guard count > 0 else { return false }
        let newIndex = max(0, min(count - 1, selectedIndex + delta))
        guard newIndex != selectedIndex else { return false }
        select(index: newIndex)
        scrollToSelection(animated: true)
        return true
    }

    func scrollToSelection(animated: Bool = false) {
        collectionView.revealCard(at: selectedIndex, animated: animated)
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
            cell.configure(with: item, highlighted: isFocused && indexPath.item == selectedIndex)
            cell.view.isHidden = item.id == draggedItemID // the dragged item's slot shows as a gap
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        select(index: indexPath.item)
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
            }, completionHandler: { [weak self] _ in
                self?.refreshHighlights()
            })
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
