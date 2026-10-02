import AppKit

final class HistoryPanelController: NSObject {
    private enum FocusedRow {
        case history
        case saved
    }

    private let store: HistoryStore
    private let savedStore: SavedStore
    /// Replaced with a fresh window on every show — see rebuildPanel().
    private var panel = HistoryPanel()
    private let contentView = KeyCatchingView()
    private let stackView = NSStackView()
    private let searchOverlay = SearchOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 32))
    private let topBar = NSView()
    private let statsLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let imagePreview = ImagePreviewController()
    private let savedRow: SavedRowController
    /// Clips savedRow.view and animates open/closed via savedRowHeightConstraint.
    private let savedRowClip = NSView()
    private var savedRowHeightConstraint: NSLayoutConstraint!
    private var savedRowVisible = false
    private var focusedRow: FocusedRow = .history

    private var previousActiveApp: NSRunningApplication?
    /// Set whenever the user swipes to a different Space while the panel is visible. Reactivating
    /// `previousActiveApp` in that case would make macOS jump back to whatever Space its window
    /// lives on — instead we skip that hand-off and just let the current Space keep whatever focus
    /// it already has.
    private var spaceChangedSinceShow = false
    /// Non-nil while show() is waiting for NSApp.activate(ignoringOtherApps:) to actually land
    /// before presenting the panel. See presentPanelOnceActive().
    private var activationObserver: NSObjectProtocol?
    private var selectedIndex = 0
    private var lastRenderedIDs: [UUID] = []

    private static let panelHeight: CGFloat = 242 // base 210, +15%
    private static let edgeMargin: CGFloat = 0 // flush with the bottom of the screen's usable area
    private static let reorderPasteboardType = NSPasteboard.PasteboardType("com.local.ClipboardManager.historyReorder")
    /// Long enough for AppKit to resolve a drag (a few pixels of movement), short enough that a
    /// genuine click still feels instant.
    private static let clickActivationDelay: TimeInterval = 0.15
    private var pendingClickActivation: DispatchWorkItem?
    /// The item currently being dragged to reorder. Its cell is hidden while dragging so its slot
    /// reads as an open gap, and the model is reordered live as the cursor crosses slots so the
    /// neighbouring cards animate aside to make room.
    private var draggedItemID: UUID?

    private var displayedItems: [ClipboardItem] {
        let query = searchOverlay.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.items }
        return store.items.filter {
            ($0.textContent ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    init(store: HistoryStore, savedStore: SavedStore) {
        self.store = store
        self.savedStore = savedStore
        self.savedRow = SavedRowController(store: savedStore)
        super.init()
        setupPanel()
        setupKeyHandling()
        store.onChange = { [weak self] in self?.handleStoreChange() }
        imagePreview.onClose = { [weak self] in self?.refocusOwnPanel() }
        savedRow.onCardActivated = { [weak self] in
            self?.focusedRow = .saved
            self?.selectCurrent()
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleActiveSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        activationObserver.map(NotificationCenter.default.removeObserver)
    }

    @objc private func handleActiveSpaceChange() {
        guard panel.isVisible else { return }
        spaceChangedSinceShow = true
    }

    // MARK: - Setup

    private static let mustardColor = NSColor(srgbRed: 0.91, green: 0.82, blue: 0.53, alpha: 1.0)

    private func setupPanel() {
        contentView.wantsLayer = true
        contentView.layer?.cornerRadius = 16
        contentView.layer?.masksToBounds = true
        contentView.layer?.backgroundColor = NSColor.white.cgColor
        contentView.layer?.borderWidth = 1.5
        contentView.layer?.borderColor = NSColor.controlAccentColor.withAlphaComponent(0.4).cgColor

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

        searchOverlay.translatesAutoresizingMaskIntoConstraints = false
        searchOverlay.onTextChange = { [weak self] _ in
            self?.selectedIndex = 0
            self?.updateDisplay(animated: false)
        }
        searchOverlay.onReturn = { [weak self] shift in self?.selectCurrent(plainText: shift) }
        searchOverlay.onEscape = { [weak self] in self?.handleSearchFieldEscape() }

        statsLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statsLabel.textColor = .secondaryLabelColor
        statsLabel.alignment = .right
        statsLabel.lineBreakMode = .byTruncatingTail
        statsLabel.setContentHuggingPriority(.required, for: .horizontal)
        statsLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
        statsLabel.translatesAutoresizingMaskIntoConstraints = false

        topBar.wantsLayer = true
        topBar.layer?.backgroundColor = Self.mustardColor.cgColor
        topBar.layer?.cornerRadius = 8
        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(searchOverlay)
        topBar.addSubview(statsLabel)

        // Saved row: starts collapsed (height 0, hidden) so it contributes no layout space or
        // stack spacing until setSavedRowVisible(true) reveals it. savedRow.view keeps its own
        // fixed height and is bottom-anchored in the clip, so as the clip grows the row appears
        // to rise into view from the bottom rather than just abruptly appearing.
        savedRowClip.wantsLayer = true
        savedRowClip.layer?.masksToBounds = true
        savedRowClip.translatesAutoresizingMaskIntoConstraints = false
        savedRowClip.isHidden = true

        savedRow.view.translatesAutoresizingMaskIntoConstraints = false
        savedRowClip.addSubview(savedRow.view)

        savedRowHeightConstraint = savedRowClip.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            savedRowHeightConstraint,
            savedRow.view.leadingAnchor.constraint(equalTo: savedRowClip.leadingAnchor),
            savedRow.view.trailingAnchor.constraint(equalTo: savedRowClip.trailingAnchor),
            savedRow.view.bottomAnchor.constraint(equalTo: savedRowClip.bottomAnchor),
            savedRow.view.heightAnchor.constraint(equalToConstant: SavedRowController.rowHeight),
        ])

        stackView.orientation = .vertical
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        stackView.addArrangedSubview(topBar)
        stackView.addArrangedSubview(scrollView)
        stackView.addArrangedSubview(savedRowClip)
        stackView.translatesAutoresizingMaskIntoConstraints = false

        contentView.addSubview(stackView)
        NSLayoutConstraint.activate([
            stackView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stackView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stackView.topAnchor.constraint(equalTo: contentView.topAnchor),
            stackView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            topBar.leadingAnchor.constraint(equalTo: stackView.leadingAnchor),
            topBar.trailingAnchor.constraint(equalTo: stackView.trailingAnchor),
            topBar.heightAnchor.constraint(equalToConstant: 34),

            searchOverlay.centerXAnchor.constraint(equalTo: topBar.centerXAnchor),
            searchOverlay.topAnchor.constraint(equalTo: topBar.topAnchor, constant: 3),
            searchOverlay.bottomAnchor.constraint(equalTo: topBar.bottomAnchor, constant: -3),
            searchOverlay.widthAnchor.constraint(equalTo: topBar.widthAnchor, multiplier: 1.0 / 3.0, constant: -8),

            // Hugs its own content and stays pinned to the right edge, rather than stretching.
            statsLabel.leadingAnchor.constraint(greaterThanOrEqualTo: searchOverlay.trailingAnchor, constant: 14),
            statsLabel.trailingAnchor.constraint(equalTo: topBar.trailingAnchor, constant: -12),
            statsLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
        ])

        panel.contentView = contentView
    }

    private func setupKeyHandling() {
        contentView.onLeftArrow = { [weak self] in self?.moveSelection(by: -1) }
        contentView.onRightArrow = { [weak self] in self?.moveSelection(by: 1) }
        contentView.onDownArrow = { [weak self] in self?.handleDownArrow() }
        contentView.onUpArrow = { [weak self] in self?.handleUpArrow() }
        contentView.onEnter = { [weak self] in self?.selectCurrent() }
        contentView.onShiftEnter = { [weak self] in self?.selectCurrent(plainText: true) }
        contentView.onSpace = { [weak self] in self?.handleSpace() }
        contentView.onDelete = { [weak self] in self?.handleDelete() }
        contentView.onCommandReturn = { [weak self] in self?.openLinkIfCurrentIsURL() }
        contentView.onCommandS = { [weak self] in self?.saveCurrentToSaved() }
        contentView.onFind = { [weak self] in self?.activateSearch() }
        contentView.onEscape = { [weak self] in self?.handleEscape() }
    }

    // MARK: - Show / hide

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    private func show() {
        let current = NSWorkspace.shared.frontmostApplication
        if current?.bundleIdentifier != Bundle.main.bundleIdentifier {
            previousActiveApp = current
        }
        spaceChangedSinceShow = false

        // Genuinely activate: a nonactivating panel can visually appear without this, but Quick
        // Look's own window doesn't reliably take real keyboard focus unless our app is the
        // truly active one — without it, keystrokes fall through to whatever app was active before.
        // Being an accessory app (no Dock icon / not in Cmd+Tab), this stays unobtrusive.
        NSApp.activate(ignoringOtherApps: true)
        presentPanelOnceActive()
    }

    /// Activation is asynchronous, so ordering the panel front before it actually lands can race
    /// the WindowServer's registration of this app as active on the *current* Space — with
    /// .canJoinAllSpaces that left the panel appearing on every other Space but not the one
    /// actually in front. A single deferred run loop turn covers a cold activation, but right after
    /// a sleep/wake cycle activation can take noticeably longer while the WindowServer re-establishes
    /// display/session state, so wait for the real completion signal instead, with a timeout as a
    /// backstop in case the notification never arrives.
    private func presentPanelOnceActive() {
        activationObserver.map(NotificationCenter.default.removeObserver)
        activationObserver = nil

        guard !NSApp.isActive else {
            presentPanel()
            return
        }

        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            self?.finishPendingPresent()
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.finishPendingPresent()
        }
    }

    private func finishPendingPresent() {
        guard let observer = activationObserver else { return }
        NotificationCenter.default.removeObserver(observer)
        activationObserver = nil
        presentPanel()
    }

    /// After a sleep/wake cycle the WindowServer can be left with stale per-Space membership for
    /// a long-lived .canJoinAllSpaces window: it shows on every Space except the active one, and
    /// neither re-setting collectionBehavior nor waiting for activation repairs it. A brand-new
    /// window carries no such state, so each show gets its own and just adopts the content view.
    private func rebuildPanel() {
        panel.contentView = nil
        panel.close()
        panel = HistoryPanel()
        panel.contentView = contentView
    }

    private func presentPanel() {
        rebuildPanel()

        searchOverlay.reset()
        selectedIndex = 0
        updateStats()

        // The saved row always starts collapsed on a fresh open — Down reveals it again each time.
        focusedRow = .history
        savedRowVisible = false
        savedRowHeightConstraint.constant = 0
        savedRowClip.isHidden = true

        guard let target = targetPanelFrame(savedRowVisible: false) else { return }
        let startFrame = NSRect(x: target.minX, y: target.minY - 24, width: target.width, height: target.height)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0

        collectionView.reloadData()
        lastRenderedIDs = displayedItems.map { $0.id }

        panel.orderFrontRegardless()
        if !panel.isOnActiveSpace {
            // Backstop: ask for the active Space explicitly instead of relying on all-Spaces
            // membership having been applied to the one in front.
            NSLog("History panel not on the active Space after ordering front; moving it there")
            panel.orderOut(nil)
            panel.collectionBehavior = [.moveToActiveSpace, .stationary, .ignoresCycle, .fullScreenAuxiliary]
            panel.orderFrontRegardless()
        }
        panel.makeKey()
        panel.makeFirstResponder(contentView)
        scrollToSelection()

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.28
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    private func hide() {
        imagePreview.hide()
        guard panel.isVisible else { return }

        let current = panel.frame
        let downFrame = NSRect(x: current.minX, y: current.minY - 24, width: current.width, height: current.height)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.2
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            panel.animator().setFrame(downFrame, display: true)
            panel.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            guard let self else { return }
            self.panel.orderOut(nil)
            if !self.spaceChangedSinceShow {
                self.previousActiveApp?.activate(options: [])
            }
            self.previousActiveApp = nil
        })
    }

    private func refocusOwnPanel() {
        guard panel.isVisible else { return }
        panel.makeKey()
        panel.makeFirstResponder(contentView)
    }

    private func targetPanelFrame(savedRowVisible: Bool) -> NSRect? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return nil }
        let visible = screen.visibleFrame
        // stackView.spacing (6) only applies once the saved row's arranged subview is un-hidden.
        let extra = savedRowVisible ? SavedRowController.rowHeight + stackView.spacing : 0
        let height = Self.panelHeight + extra
        return NSRect(x: visible.minX, y: visible.minY + Self.edgeMargin, width: visible.width, height: height)
    }

    /// Grows/shrinks the panel to reveal or collapse the saved row, animating the height
    /// constraint and the panel's frame together so the row appears to rise into place from the
    /// bottom edge (the panel is already flush with the screen bottom, so there's no room below it
    /// — the main row shifts up slightly to make room instead).
    private func setSavedRowVisible(_ visible: Bool) {
        guard savedRowVisible != visible else { return }
        savedRowVisible = visible
        guard let target = targetPanelFrame(savedRowVisible: visible) else { return }

        if visible {
            savedRow.reload()
            savedRowClip.isHidden = false
        }

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            savedRowHeightConstraint.animator().constant = visible ? SavedRowController.rowHeight : 0
            panel.animator().setFrame(target, display: true)
        }, completionHandler: { [weak self] in
            guard let self else { return }
            if visible {
                self.savedRow.scrollToSelection()
            } else if !self.savedRowVisible {
                self.savedRowClip.isHidden = true
            }
        })
    }

    private func handleDownArrow() {
        guard focusedRow == .history else { return }
        focusedRow = .saved
        savedRow.resetSelection()
        setSavedRowVisible(true)
    }

    private func handleUpArrow() {
        guard focusedRow == .saved else { return }
        collapseSavedRow()
    }

    private func collapseSavedRow() {
        focusedRow = .history
        setSavedRowVisible(false)
    }

    // MARK: - Navigation & actions

    /// Reconciles the collection view with the current `displayedItems`.
    /// When `animated`, a single insert/move is shown with a smooth batch update and the new
    /// card gets a brief highlight pulse; anything larger (search filtering, bulk eviction) just reloads.
    private func updateDisplay(animated: Bool) {
        let newIDs = displayedItems.map { $0.id }
        let oldIDs = lastRenderedIDs
        defer { lastRenderedIDs = newIDs }

        guard animated, !oldIDs.isEmpty, oldIDs != newIDs else {
            selectedIndex = min(selectedIndex, max(displayedItems.count - 1, 0))
            collectionView.reloadData()
            scrollToSelection()
            return
        }

        let removedIDs = Set(oldIDs).subtracting(newIDs)
        let addedIDs = Set(newIDs).subtracting(oldIDs)

        // Keep whichever item the user was looking at highlighted, even as new items land at the front.
        // If it was the one removed, the highlight lands on whatever slides into its slot.
        if selectedIndex < oldIDs.count {
            let highlightedID = oldIDs[selectedIndex]
            if let newIndex = newIDs.firstIndex(of: highlightedID) {
                selectedIndex = newIndex
            }
        }
        selectedIndex = min(selectedIndex, max(newIDs.count - 1, 0))

        guard removedIDs.count <= 1, addedIDs.count <= 1 else {
            selectedIndex = min(selectedIndex, max(displayedItems.count - 1, 0))
            collectionView.reloadData()
            scrollToSelection()
            return
        }

        collectionView.animator().performBatchUpdates({
            for (index, id) in oldIDs.enumerated() where removedIDs.contains(id) {
                collectionView.deleteItems(at: [IndexPath(item: index, section: 0)])
            }
            for (index, id) in newIDs.enumerated() where addedIDs.contains(id) {
                collectionView.insertItems(at: [IndexPath(item: index, section: 0)])
            }
            for (newIndex, id) in newIDs.enumerated() where !addedIDs.contains(id) {
                if let oldIndex = oldIDs.firstIndex(of: id), oldIndex != newIndex {
                    collectionView.moveItem(at: IndexPath(item: oldIndex, section: 0), to: IndexPath(item: newIndex, section: 0))
                }
            }
        }, completionHandler: { [weak self] _ in
            guard let self else { return }
            // A cell that slid into the highlighted slot was never reconfigured, so refresh it.
            if self.selectedIndex < self.displayedItems.count {
                self.collectionView.reloadItems(at: [IndexPath(item: self.selectedIndex, section: 0)])
            }
            self.scrollToSelection()
            if let newID = addedIDs.first, let newIndex = newIDs.firstIndex(of: newID),
               let cell = self.collectionView.item(at: IndexPath(item: newIndex, section: 0)) as? HistoryItemView {
                cell.playInsertionAnimation()
            }
        })
    }

    private func handleStoreChange() {
        guard panel.isVisible else { return }
        updateStats()
        updateDisplay(animated: true)
    }

    private func updateStats() {
        let items = store.items
        let linkCount = items.filter { $0.type == .url }.count
        let imageCount = items.filter { $0.type == .image }.count
        statsLabel.stringValue = "\(items.count) items · \(linkCount) links · \(imageCount) images"
    }

    private func moveSelection(by delta: Int) {
        imagePreview.hide()
        switch focusedRow {
        case .history:
            let count = displayedItems.count
            guard count > 0 else { return }
            selectedIndex = max(0, min(count - 1, selectedIndex + delta))
            collectionView.reloadData()
            scrollToSelection()
        case .saved:
            savedRow.moveSelection(by: delta)
        }
    }

    private func scrollToSelection() {
        guard selectedIndex < displayedItems.count else { return }
        collectionView.scrollToItems(at: [IndexPath(item: selectedIndex, section: 0)], scrollPosition: .centeredHorizontally)
    }

    /// The item currently highlighted in whichever row has focus.
    private var focusedItem: ClipboardItem? {
        switch focusedRow {
        case .history: return selectedIndex < displayedItems.count ? displayedItems[selectedIndex] : nil
        case .saved: return savedRow.selectedItem()
        }
    }

    /// `plainText` (⇧Enter) strips any captured RTF/HTML from the paste.
    private func selectCurrent(plainText: Bool = false) {
        guard let item = focusedItem else { return }
        switch focusedRow {
        case .history: store.moveToTop(id: item.id)
        case .saved: savedStore.moveToTop(id: item.id)
        }
        PasteboardWriter.write(item, plainTextOnly: plainText)
        hide()
    }

    private func handleSpace() {
        guard let item = focusedItem, item.type == .image, let fileName = item.imageFileName else { return }

        if imagePreview.isVisible {
            imagePreview.hide()
        } else {
            let fileURL = ImageStore.imagesDirectory.appendingPathComponent(fileName)
            imagePreview.show(fileURL: fileURL)
        }
    }

    private func openLinkIfCurrentIsURL() {
        guard let item = focusedItem, item.type == .url, let url = item.detectedURL else { return }
        NSWorkspace.shared.open(url)
        hide()
    }

    /// Delete/Backspace removes the highlighted item from whichever row has focus. For history,
    /// the store's onChange drives updateDisplay(animated:), which already animates a single removal.
    private func handleDelete() {
        imagePreview.hide()
        switch focusedRow {
        case .history:
            guard let item = focusedItem else { return }
            store.remove(id: item.id)
        case .saved:
            savedRow.removeSelected()
        }
    }

    /// Cmd+S: promotes the currently-highlighted history item into the saved row. Gives feedback
    /// via a pulse on the source card regardless of whether the saved row is currently open, and
    /// also pulses the new top card in the saved row if it's visible.
    private func saveCurrentToSaved() {
        guard focusedRow == .history, selectedIndex < displayedItems.count else { return }
        let item = displayedItems[selectedIndex]
        savedStore.save(item)

        if savedRowVisible {
            savedRow.reloadAndPulseTop()
        }
        if let cell = collectionView.item(at: IndexPath(item: selectedIndex, section: 0)) as? HistoryItemView {
            cell.playInsertionAnimation()
        }
    }

    private func activateSearch() {
        guard panel.makeFirstResponder(searchOverlay.field) else { return }
        searchOverlay.field.currentEditor()?.selectAll(nil)
    }

    /// Escape pressed while the search field itself has focus: first clear the query (and hand
    /// focus back to the list so arrow keys resume browsing), then a second Escape closes the panel.
    private func handleSearchFieldEscape() {
        if searchOverlay.field.stringValue.isEmpty {
            hide()
        } else {
            searchOverlay.reset()
            selectedIndex = 0
            updateDisplay(animated: false)
            panel.makeFirstResponder(contentView)
        }
    }

    private func handleEscape() {
        if imagePreview.isVisible {
            imagePreview.hide()
        } else if focusedRow == .saved {
            collapseSavedRow()
        } else {
            hide()
        }
    }
}

// MARK: - NSCollectionViewDataSource / Delegate

extension HistoryPanelController: NSCollectionViewDataSource, NSCollectionViewDelegate {
    func collectionView(_ collectionView: NSCollectionView, numberOfItemsInSection section: Int) -> Int {
        displayedItems.count
    }

    func collectionView(_ collectionView: NSCollectionView, itemForRepresentedObjectAt indexPath: IndexPath) -> NSCollectionViewItem {
        guard let cell = collectionView.makeItem(withIdentifier: HistoryItemView.identifier, for: indexPath) as? HistoryItemView else {
            return NSCollectionViewItem()
        }
        let items = displayedItems
        if indexPath.item < items.count {
            let item = items[indexPath.item]
            cell.configure(with: item, highlighted: indexPath.item == selectedIndex)
            cell.view.isHidden = item.id == draggedItemID // the dragged item's slot shows as a gap
        }
        return cell
    }

    /// Fires on mouse-DOWN, before AppKit has decided whether the gesture is a click or the start
    /// of a drag (same as Finder icons highlighting the instant you press them). Acting on it
    /// directly used to paste+close the panel the instant a drag began. Instead, schedule the
    /// activation and cancel it in draggingSession(_:willBeginAt:forItemsAt:) below if a drag
    /// actually starts — that delegate call only fires once AppKit has confirmed real dragging.
    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        focusedRow = .history
        selectedIndex = indexPath.item
        scheduleClickActivation()
    }

    private func scheduleClickActivation() {
        pendingClickActivation?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.selectCurrent() }
        pendingClickActivation = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.clickActivationDelay, execute: work)
    }

    func collectionView(
        _ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
        willBeginAt screenPoint: NSPoint, forItemsAt indexPaths: Set<IndexPath>
    ) {
        pendingClickActivation?.cancel()
        pendingClickActivation = nil
        guard let index = indexPaths.first?.item, index < displayedItems.count else { return }
        draggedItemID = displayedItems[index].id
        collectionView.item(at: IndexPath(item: index, section: 0))?.view.isHidden = true
    }

    func collectionView(
        _ collectionView: NSCollectionView, draggingSession session: NSDraggingSession,
        endedAt screenPoint: NSPoint, dragOperation operation: NSDragOperation
    ) {
        clearDragState()
    }

    /// Un-hides the dragged item's cell (wherever it now sits) and forgets it. Safe to call twice —
    /// acceptDrop and endedAt both call it, whichever runs first wins.
    private func clearDragState() {
        guard let id = draggedItemID else { return }
        draggedItemID = nil
        if let index = displayedItems.firstIndex(where: { $0.id == id }) {
            collectionView.item(at: IndexPath(item: index, section: 0))?.view.isHidden = false
        }
    }

    // MARK: - Drag to reorder

    /// Reordering is only well-defined against the unfiltered list, so it's disabled while search is active.
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard searchOverlay.field.stringValue.isEmpty else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(indexPath.item), forType: Self.reorderPasteboardType)
        return pasteboardItem
    }

    func collectionView(
        _ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard searchOverlay.field.stringValue.isEmpty, let draggedItemID,
              let currentIndex = displayedItems.firstIndex(where: { $0.id == draggedItemID }) else { return [] }
        proposedDropOperation.pointee = .before

        // Live reorder: shift the dragged item to wherever the cursor now points, so the store's
        // onChange animates the neighbouring cards aside (the dragged cell stays hidden = the gap).
        let proposed = min(max(proposedDropIndexPath.pointee.item, 0), displayedItems.count)
        let destination = min(proposed > currentIndex ? proposed - 1 : proposed, displayedItems.count - 1)
        if destination != currentIndex {
            store.moveItem(id: draggedItemID, toIndex: destination)
        }
        return .move
    }

    func collectionView(
        _ collectionView: NSCollectionView, acceptDrop draggingInfo: NSDraggingInfo,
        indexPath: IndexPath, dropOperation: NSCollectionView.DropOperation
    ) -> Bool {
        // The live moves in validateDrop already placed the item; just settle and commit.
        clearDragState()
        focusedRow = .history
        return true
    }
}
