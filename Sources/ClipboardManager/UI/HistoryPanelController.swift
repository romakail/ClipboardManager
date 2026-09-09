import AppKit

final class HistoryPanelController: NSObject {
    private let store: HistoryStore
    private let panel = HistoryPanel()
    private let contentView = KeyCatchingView()
    private let stackView = NSStackView()
    private let searchOverlay = SearchOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 32))
    private let topBar = NSView()
    private let statsLabel = NSTextField(labelWithString: "")
    private let scrollView = NSScrollView()
    private let collectionView = NSCollectionView()
    private let imagePreview = ImagePreviewController()

    private var previousActiveApp: NSRunningApplication?
    private var selectedIndex = 0
    private var lastRenderedIDs: [UUID] = []

    private static let panelHeight: CGFloat = 242 // base 210, +15%
    private static let edgeMargin: CGFloat = 0 // flush with the bottom of the screen's usable area

    private var displayedItems: [ClipboardItem] {
        let query = searchOverlay.field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.items }
        return store.items.filter {
            ($0.textContent ?? "").localizedCaseInsensitiveContains(query)
        }
    }

    init(store: HistoryStore) {
        self.store = store
        super.init()
        setupPanel()
        setupKeyHandling()
        store.onChange = { [weak self] in self?.handleStoreChange() }
        imagePreview.onClose = { [weak self] in self?.refocusOwnPanel() }
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
        searchOverlay.onReturn = { [weak self] in self?.selectCurrent() }
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

        stackView.orientation = .vertical
        stackView.spacing = 6
        stackView.edgeInsets = NSEdgeInsets(top: 0, left: 8, bottom: 8, right: 8)
        stackView.addArrangedSubview(topBar)
        stackView.addArrangedSubview(scrollView)
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
        contentView.onEnter = { [weak self] in self?.selectCurrent() }
        contentView.onSpace = { [weak self] in self?.handleSpace() }
        contentView.onCommandReturn = { [weak self] in self?.openLinkIfCurrentIsURL() }
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

        // Genuinely activate: a nonactivating panel can visually appear without this, but Quick
        // Look's own window doesn't reliably take real keyboard focus unless our app is the
        // truly active one — without it, keystrokes fall through to whatever app was active before.
        // Being an accessory app (no Dock icon / not in Cmd+Tab), this stays unobtrusive.
        NSApp.activate(ignoringOtherApps: true)

        searchOverlay.reset()
        selectedIndex = 0
        updateStats()

        guard let target = targetPanelFrame() else { return }
        let startFrame = NSRect(x: target.minX, y: target.minY - 24, width: target.width, height: target.height)
        panel.setFrame(startFrame, display: false)
        panel.alphaValue = 0

        collectionView.reloadData()
        lastRenderedIDs = displayedItems.map { $0.id }

        panel.orderFrontRegardless()
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
            self.previousActiveApp?.activate(options: [])
            self.previousActiveApp = nil
        })
    }

    private func refocusOwnPanel() {
        guard panel.isVisible else { return }
        panel.makeKey()
        panel.makeFirstResponder(contentView)
    }

    private func targetPanelFrame() -> NSRect? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return nil }
        let visible = screen.visibleFrame
        return NSRect(x: visible.minX, y: visible.minY + Self.edgeMargin, width: visible.width, height: Self.panelHeight)
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
        if selectedIndex < oldIDs.count {
            let highlightedID = oldIDs[selectedIndex]
            if let newIndex = newIDs.firstIndex(of: highlightedID) {
                selectedIndex = newIndex
            }
        }

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
        let count = displayedItems.count
        guard count > 0 else { return }
        selectedIndex = max(0, min(count - 1, selectedIndex + delta))
        collectionView.reloadData()
        scrollToSelection()
    }

    private func scrollToSelection() {
        guard selectedIndex < displayedItems.count else { return }
        collectionView.scrollToItems(at: [IndexPath(item: selectedIndex, section: 0)], scrollPosition: .centeredHorizontally)
    }

    private func selectCurrent() {
        guard selectedIndex < displayedItems.count else { return }
        let item = displayedItems[selectedIndex]
        store.moveToTop(id: item.id)
        PasteboardWriter.write(item)
        hide()
    }

    private func handleSpace() {
        guard selectedIndex < displayedItems.count else { return }
        let item = displayedItems[selectedIndex]
        guard item.type == .image, let fileName = item.imageFileName else { return }

        if imagePreview.isVisible {
            imagePreview.hide()
        } else {
            let fileURL = ImageStore.imagesDirectory.appendingPathComponent(fileName)
            imagePreview.show(fileURL: fileURL)
        }
    }

    private func openLinkIfCurrentIsURL() {
        guard selectedIndex < displayedItems.count else { return }
        let item = displayedItems[selectedIndex]
        guard item.type == .url, let url = item.detectedURL else { return }
        NSWorkspace.shared.open(url)
        hide()
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
            cell.configure(with: items[indexPath.item], highlighted: indexPath.item == selectedIndex)
        }
        return cell
    }

    func collectionView(_ collectionView: NSCollectionView, didSelectItemsAt indexPaths: Set<IndexPath>) {
        guard let indexPath = indexPaths.first else { return }
        selectedIndex = indexPath.item
        selectCurrent()
    }
}
