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
    private let backdrop = NSVisualEffectView()
    private let topBar = NSView()
    private let filterBar = FilterBarView()
    private let searchOverlay = SearchOverlayView(frame: NSRect(x: 0, y: 0, width: 100, height: 28))
    private let hintLabel = NSTextField(labelWithString: "")
    private let scrollView = HorizontalScrollView()
    private let collectionView = CardCollectionView()
    private let emptyLabel = NSTextField(labelWithString: "")
    private let imagePreview = ImagePreviewController()
    private let savedRow: SavedRowController
    /// Clips savedRow.view and animates open/closed via savedRowHeightConstraint.
    private let savedRowClip = NSView()
    private var savedRowHeightConstraint: NSLayoutConstraint!
    private var savedRowVisible = false
    private var focusedRow: FocusedRow = .history {
        didSet { focusDidChange() }
    }

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
    /// True while ⌘ is held with the panel open, which reveals the ⌘1–9 quick-paste badges.
    private var commandHeld = false

    private static let reorderPasteboardType = NSPasteboard.PasteboardType("com.local.ClipboardManager.historyReorder")
    /// Long enough for AppKit to resolve a drag (a few pixels of movement), short enough that a
    /// genuine click still feels instant.
    private static let clickActivationDelay: TimeInterval = 0.15
    private var pendingClickActivation: DispatchWorkItem?
    /// The item currently being dragged to reorder. Its cell is hidden while dragging so its slot
    /// reads as an open gap, and the model is reordered live as the cursor crosses slots so the
    /// neighbouring cards animate aside to make room.
    private var draggedItemID: UUID?

    /// Where text clips are written so Quick Look has a file to show; emptied when the panel closes.
    private static let previewDirectory = FileManager.default.temporaryDirectory
        .appendingPathComponent("ClipboardManagerPreview", isDirectory: true)

    // MARK: - Filtering

    /// True when the row shows a subset of history (a search query or a type chip is active).
    private var isFiltering: Bool {
        !searchOverlay.query.isEmpty || filterBar.selected != .all
    }

    /// Memoised result of filtering `store.items`; this is read once per card while the row
    /// draws, so it's only recomputed after the store, the query or the type filter changes.
    private var displayedCache: [ClipboardItem]?

    private var displayedItems: [ClipboardItem] {
        if let displayedCache { return displayedCache }

        let tokens = searchOverlay.query.split(whereSeparator: \.isWhitespace).map(String.init)
        let filter = filterBar.selected
        let result: [ClipboardItem]
        if tokens.isEmpty, filter == .all {
            result = store.items
        } else {
            result = store.items.filter { filter.matches($0) && $0.matches(searchTokens: tokens) }
        }
        displayedCache = result
        return result
    }

    init(store: HistoryStore, savedStore: SavedStore) {
        self.store = store
        self.savedStore = savedStore
        self.savedRow = SavedRowController(store: savedStore)
        super.init()
        setupPanel()
        setupKeyHandling()
        store.onChange = { [weak self] in
            self?.displayedCache = nil
            self?.handleStoreChange()
        }
        imagePreview.onClose = { [weak self] in self?.refocusOwnPanel() }
        savedRow.onCardActivated = { [weak self] in
            self?.focusedRow = .saved
            self?.selectCurrent()
        }
        savedRow.menuProvider = { [weak self] in
            guard let self else { return nil }
            self.focusedRow = .saved
            return self.focusedItem.map(self.contextMenu(for:))
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(handleActiveSpaceChange),
            name: NSWorkspace.activeSpaceDidChangeNotification, object: nil
        )
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        NotificationCenter.default.removeObserver(self)
        activationObserver.map(NotificationCenter.default.removeObserver)
    }

    @objc private func handleActiveSpaceChange() {
        guard panel.isVisible else { return }
        spaceChangedSinceShow = true
    }

    // MARK: - Setup

    private func setupPanel() {
        contentView.cornerRadius = PanelMetrics.cornerRadius
        contentView.strokeColor = NSColor.labelColor.withAlphaComponent(0.16)
        contentView.strokeWidth = 1

        // Frosted backdrop: follows light/dark mode and lets the desktop show through.
        backdrop.material = .popover
        backdrop.blendingMode = .behindWindow
        backdrop.state = .active
        backdrop.maskImage = Styling.roundedMask(radius: PanelMetrics.cornerRadius)
        backdrop.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(backdrop)

        collectionView.configureAsCardRow(in: scrollView, reorderType: Self.reorderPasteboardType)
        collectionView.dataSource = self
        collectionView.delegate = self
        collectionView.menuProvider = { [weak self] indexPath in
            guard let self else { return nil }
            self.focusedRow = .history
            self.setSelectedIndex(indexPath.item)
            return self.focusedItem.map(self.contextMenu(for:))
        }
        // The quick-paste badges number the cards from the first visible one, so they have to
        // follow the row as it scrolls.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(
            self, selector: #selector(historyRowDidScroll),
            name: NSView.boundsDidChangeNotification, object: scrollView.contentView
        )

        searchOverlay.translatesAutoresizingMaskIntoConstraints = false
        searchOverlay.onTextChange = { [weak self] _ in self?.filterDidChange() }
        searchOverlay.onReturn = { [weak self] shift in self?.selectCurrent(plainText: shift) }
        searchOverlay.onEscape = { [weak self] in self?.handleSearchFieldEscape() }
        searchOverlay.onHorizontalArrow = { [weak self] delta in self?.moveSelection(by: delta) }
        searchOverlay.onVerticalArrow = { [weak self] delta in
            if delta > 0 { self?.handleDownArrow() } else { self?.handleUpArrow() }
        }
        searchOverlay.onTab = { [weak self] backwards in self?.filterBar.cycle(by: backwards ? -1 : 1) }
        searchOverlay.onBackspaceWhenEmpty = { [weak self] in self?.focusCardList() }

        filterBar.translatesAutoresizingMaskIntoConstraints = false
        filterBar.onChange = { [weak self] _ in self?.filterDidChange() }

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.alignment = .right
        hintLabel.lineBreakMode = .byTruncatingHead
        hintLabel.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        hintLabel.translatesAutoresizingMaskIntoConstraints = false

        topBar.translatesAutoresizingMaskIntoConstraints = false
        topBar.addSubview(filterBar)
        topBar.addSubview(searchOverlay)
        topBar.addSubview(hintLabel)

        emptyLabel.font = .systemFont(ofSize: 13)
        emptyLabel.textColor = .secondaryLabelColor
        emptyLabel.alignment = .center
        emptyLabel.isHidden = true
        emptyLabel.translatesAutoresizingMaskIntoConstraints = false

        // Saved row: starts collapsed (height 0, hidden) until setSavedRowVisible(true) reveals
        // it. savedRow.view keeps its own fixed height and is bottom-anchored in the clip, so as
        // the clip grows the row appears to rise into view rather than abruptly appearing.
        savedRowClip.wantsLayer = true
        savedRowClip.layer?.masksToBounds = true
        savedRowClip.translatesAutoresizingMaskIntoConstraints = false
        savedRowClip.isHidden = true

        savedRow.view.translatesAutoresizingMaskIntoConstraints = false
        savedRowClip.addSubview(savedRow.view)

        contentView.addSubview(topBar)
        contentView.addSubview(scrollView)
        contentView.addSubview(emptyLabel)
        contentView.addSubview(savedRowClip)

        let centeredSearch = searchOverlay.centerXAnchor.constraint(equalTo: topBar.centerXAnchor)
        centeredSearch.priority = .defaultHigh
        let searchWidth = searchOverlay.widthAnchor.constraint(equalToConstant: 300)
        searchWidth.priority = .defaultHigh

        savedRowHeightConstraint = savedRowClip.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            backdrop.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            backdrop.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            backdrop.topAnchor.constraint(equalTo: contentView.topAnchor),
            backdrop.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),

            topBar.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 14),
            topBar.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -16),
            topBar.topAnchor.constraint(equalTo: contentView.topAnchor, constant: PanelMetrics.topPadding),
            topBar.heightAnchor.constraint(equalToConstant: PanelMetrics.topBarHeight),

            filterBar.leadingAnchor.constraint(equalTo: topBar.leadingAnchor),
            filterBar.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            // Centered when there's room; on a narrow screen it yields to the filter chips.
            centeredSearch,
            searchWidth,
            searchOverlay.leadingAnchor.constraint(greaterThanOrEqualTo: filterBar.trailingAnchor, constant: 12),
            searchOverlay.trailingAnchor.constraint(lessThanOrEqualTo: topBar.trailingAnchor),
            searchOverlay.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),
            searchOverlay.heightAnchor.constraint(equalToConstant: 28),

            hintLabel.leadingAnchor.constraint(greaterThanOrEqualTo: searchOverlay.trailingAnchor, constant: 14),
            hintLabel.trailingAnchor.constraint(equalTo: topBar.trailingAnchor),
            hintLabel.centerYAnchor.constraint(equalTo: topBar.centerYAnchor),

            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: topBar.bottomAnchor, constant: 2),
            scrollView.heightAnchor.constraint(equalToConstant: PanelMetrics.rowHeight),

            emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
            emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),

            savedRowClip.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            savedRowClip.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            savedRowClip.topAnchor.constraint(equalTo: scrollView.bottomAnchor),
            savedRowHeightConstraint,

            savedRow.view.leadingAnchor.constraint(equalTo: savedRowClip.leadingAnchor),
            savedRow.view.trailingAnchor.constraint(equalTo: savedRowClip.trailingAnchor),
            savedRow.view.bottomAnchor.constraint(equalTo: savedRowClip.bottomAnchor),
            savedRow.view.heightAnchor.constraint(equalToConstant: SavedRowController.rowHeight),
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
        contentView.onSpace = { [weak self] in self?.togglePreview() }
        contentView.onDelete = { [weak self] in self?.handleDelete() }
        contentView.onCommandDelete = { [weak self] in self?.handleDelete() }
        contentView.onCommandReturn = { [weak self] in self?.openLinkIfCurrentIsURL() }
        contentView.onCommandS = { [weak self] in self?.saveCurrentToSaved() }
        contentView.onCommandC = { [weak self] in self?.selectCurrent(copyOnly: true) }
        contentView.onFind = { [weak self] in self?.activateSearch() }
        contentView.onEscape = { [weak self] in self?.handleEscape() }
        contentView.onTab = { [weak self] backwards in self?.filterBar.cycle(by: backwards ? -1 : 1) }
        contentView.onQuickPaste = { [weak self] number in self?.quickPaste(number) }
        contentView.onCommandKeyChanged = { [weak self] isDown in self?.setCommandHeld(isDown) }
        contentView.onTypeToSearch = { [weak self] event in self?.beginTypeToSearch(with: event) }
    }

    // MARK: - Show / hide

    func toggle() {
        if panel.isVisible {
            hide()
        } else {
            show()
        }
    }

    func show() {
        guard !panel.isVisible else { return }
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
        filterBar.select(.all, notify: false)
        displayedCache = nil
        commandHeld = false
        selectedIndex = 0
        updateHint()

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
        updateEmptyState()

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
        collectionView.revealCard(at: 0, animated: false)

        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.24
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrame(target, display: true)
            panel.animator().alphaValue = 1
        }
    }

    /// Closes the panel. With `pasteIntoPreviousApp`, the app the user came from is brought back
    /// and sent ⌘V so the chosen item lands right where they were typing — provided direct paste
    /// is switched on and permitted; otherwise the item simply stays on the pasteboard.
    private func hide(pasteIntoPreviousApp: Bool = false) {
        imagePreview.hide()
        guard panel.isVisible else { return }
        pendingClickActivation?.cancel()
        setCommandHeld(false)
        try? FileManager.default.removeItem(at: Self.previewDirectory)

        let closingPanel = panel
        let targetApp = spaceChangedSinceShow ? nil : previousActiveApp
        previousActiveApp = nil
        let shouldPaste = pasteIntoPreviousApp && targetApp != nil && DirectPaste.isActive

        // When pasting, hand focus back right away instead of after the fade: the target app is
        // then already frontmost by the time the keystroke is due.
        if shouldPaste {
            targetApp?.activate(options: [])
        }

        let current = closingPanel.frame
        let downFrame = NSRect(x: current.minX, y: current.minY - 24, width: current.width, height: current.height)

        NSAnimationContext.runAnimationGroup({ context in
            context.duration = shouldPaste ? 0.12 : 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeIn)
            closingPanel.animator().setFrame(downFrame, display: true)
            closingPanel.animator().alphaValue = 0
        }, completionHandler: {
            closingPanel.orderOut(nil)
            guard let targetApp else { return }
            if shouldPaste {
                DirectPaste.paste(into: targetApp)
            } else {
                targetApp.activate(options: [])
            }
        })
    }

    private func refocusOwnPanel() {
        guard panel.isVisible else { return }
        panel.makeKey()
        focusCardList()
    }

    /// Gives keyboard focus to the cards (as opposed to the search field).
    private func focusCardList() {
        panel.makeFirstResponder(contentView)
    }

    private func targetPanelFrame(savedRowVisible: Bool) -> NSRect? {
        let mouseLocation = NSEvent.mouseLocation
        let screen = NSScreen.screens.first(where: { NSMouseInRect(mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screen else { return nil }
        let visible = screen.visibleFrame.insetBy(dx: PanelMetrics.screenMargin, dy: 0)
        let height = PanelMetrics.baseHeight + (savedRowVisible ? SavedRowController.rowHeight : 0)
        return NSRect(x: visible.minX, y: visible.minY + PanelMetrics.screenMargin, width: visible.width, height: height)
    }

    /// Grows/shrinks the panel to reveal or collapse the saved row, animating the height
    /// constraint and the panel's frame together so the row appears to rise into place from the
    /// bottom edge (the main row shifts up to make room).
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
        imagePreview.hide()
        focusedRow = .saved
        savedRow.resetSelection()
        setSavedRowVisible(true)
    }

    private func handleUpArrow() {
        guard focusedRow == .saved else { return }
        imagePreview.hide()
        collapseSavedRow()
    }

    private func collapseSavedRow() {
        focusedRow = .history
        setSavedRowVisible(false)
    }

    // MARK: - Display

    /// Reconciles the collection view with the current `displayedItems`.
    /// When `animated`, a single insert/move is shown with a smooth batch update and the new
    /// card gets a brief highlight pulse; anything larger (search filtering, bulk eviction) just reloads.
    private func updateDisplay(animated: Bool) {
        let newIDs = displayedItems.map { $0.id }
        let oldIDs = lastRenderedIDs
        defer {
            lastRenderedIDs = newIDs
            updateEmptyState()
        }

        guard animated, !oldIDs.isEmpty, oldIDs != newIDs else {
            reloadRow()
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
            reloadRow()
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
            // Cards that slid into new slots keep their old ring/badge state, so refresh both.
            self.refreshHighlights()
            self.refreshQuickPasteBadges()
            self.collectionView.revealCard(at: self.selectedIndex, animated: true)
            if let newID = addedIDs.first, let newIndex = newIDs.firstIndex(of: newID),
               let cell = self.collectionView.item(at: IndexPath(item: newIndex, section: 0)) as? HistoryItemView {
                cell.playInsertionAnimation()
            }
        })
    }

    private func reloadRow() {
        selectedIndex = min(selectedIndex, max(displayedItems.count - 1, 0))
        collectionView.reloadData()
        collectionView.revealCard(at: selectedIndex, animated: false)
    }

    private func handleStoreChange() {
        guard panel.isVisible else { return }
        updateDisplay(animated: true)
    }

    /// The search query or the type chip changed: start again from the first match.
    private func filterDidChange() {
        displayedCache = nil
        imagePreview.hide()
        if focusedRow == .saved {
            collapseSavedRow()
        }
        selectedIndex = 0
        updateDisplay(animated: false)
    }

    private func updateEmptyState() {
        emptyLabel.isHidden = !displayedItems.isEmpty
        emptyLabel.stringValue = isFiltering
            ? "Nothing found"
            : "Your clipboard history is empty — copy something and it will show up here"
    }

    private func updateHint() {
        let primary = DirectPaste.isActive ? "↩ Paste" : "↩ Copy"
        hintLabel.stringValue = [primary, "⇧↩ Plain Text", "⌘1–9 Quick Paste", "⌘S Save", "Space Preview", "↓ Saved"]
            .joined(separator: "     ")
    }

    // MARK: - Selection

    private func focusDidChange() {
        savedRow.isFocused = focusedRow == .saved
        refreshHighlights()
        refreshQuickPasteBadges()
    }

    /// Moves the highlight by restyling just the affected cards. Rebuilding the whole row here
    /// (as a reload would) re-decodes every visible thumbnail on each arrow press.
    private func setSelectedIndex(_ index: Int) {
        selectedIndex = index
        refreshHighlights()
    }

    private func refreshHighlights() {
        for (index, card) in collectionView.visibleCards() {
            card.setHighlighted(focusedRow == .history && index == selectedIndex)
        }
    }

    private func moveSelection(by delta: Int) {
        imagePreview.hide()
        switch focusedRow {
        case .history:
            let count = displayedItems.count
            guard count > 0 else { return }
            setSelectedIndex(max(0, min(count - 1, selectedIndex + delta)))
            collectionView.revealCard(at: selectedIndex, animated: true)
        case .saved:
            savedRow.moveSelection(by: delta)
        }
    }

    /// The item currently highlighted in whichever row has focus.
    private var focusedItem: ClipboardItem? {
        switch focusedRow {
        case .history: return selectedIndex < displayedItems.count ? displayedItems[selectedIndex] : nil
        case .saved: return savedRow.selectedItem()
        }
    }

    // MARK: - Quick paste (⌘1–9)

    private func setCommandHeld(_ held: Bool) {
        guard commandHeld != held else { return }
        commandHeld = held
        refreshQuickPasteBadges()
    }

    @objc private func historyRowDidScroll() {
        guard commandHeld else { return }
        refreshQuickPasteBadges()
    }

    /// Index of the first card that's (mostly) on screen: ⌘1 always means "the leftmost card I can see".
    private func quickPasteBaseIndex() -> Int {
        let visibleMinX = scrollView.contentView.bounds.minX
        let stride = HistoryItemView.cardSize.width + PanelMetrics.cardSpacing
        let firstCardMidX = PanelMetrics.rowInsets.left + HistoryItemView.cardSize.width / 2
        return max(0, Int(((visibleMinX - firstCardMidX) / stride).rounded(.up)))
    }

    private func refreshQuickPasteBadges() {
        let showBadges = commandHeld && focusedRow == .history
        let base = quickPasteBaseIndex()
        for (index, card) in collectionView.visibleCards() {
            let number = index - base + 1
            card.setQuickPasteNumber(showBadges && (1...9).contains(number) ? number : nil)
        }
    }

    private func quickPaste(_ number: Int) {
        guard focusedRow == .history else { return }
        let index = quickPasteBaseIndex() + number - 1
        guard index < displayedItems.count else { return }
        activate(displayedItems[index], in: .history)
    }

    // MARK: - Actions

    /// `plainText` (⇧Enter) strips any captured RTF/HTML from the paste; `copyOnly` (⌘C) puts the
    /// item on the pasteboard without pasting it anywhere.
    private func selectCurrent(plainText: Bool = false, copyOnly: Bool = false) {
        guard let item = focusedItem else { return }
        activate(item, in: focusedRow, plainText: plainText, copyOnly: copyOnly)
    }

    private func activate(_ item: ClipboardItem, in row: FocusedRow, plainText: Bool = false, copyOnly: Bool = false) {
        switch row {
        case .history: store.moveToTop(id: item.id)
        case .saved: savedStore.moveToTop(id: item.id)
        }
        PasteboardWriter.write(item, plainTextOnly: plainText)
        hide(pasteIntoPreviousApp: !copyOnly)
    }

    /// Space: Quick Look for the highlighted item — images as-is, text and links via a temp file.
    private func togglePreview() {
        if imagePreview.isVisible {
            imagePreview.hide()
            return
        }
        guard let item = focusedItem, let fileURL = previewFileURL(for: item) else { return }
        imagePreview.show(fileURL: fileURL)
    }

    private func previewFileURL(for item: ClipboardItem) -> URL? {
        switch item.type {
        case .image:
            return item.imageFileName.map { ImageStore.imagesDirectory.appendingPathComponent($0) }
        case .text, .url:
            let directory = Self.previewDirectory
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let (fileName, data): (String, Data)
            if let rtf = item.rtfData {
                (fileName, data) = ("Clipboard.rtf", rtf)
            } else {
                (fileName, data) = ("Clipboard.txt", Data((item.textContent ?? "").utf8))
            }
            let fileURL = directory.appendingPathComponent(fileName)
            do {
                try data.write(to: fileURL, options: .atomic)
                return fileURL
            } catch {
                return nil
            }
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

    // MARK: - Search

    private func activateSearch() {
        guard panel.makeFirstResponder(searchOverlay.field) else { return }
        searchOverlay.field.currentEditor()?.selectAll(nil)
    }

    /// Typing anywhere in the panel starts a search: focus moves to the field and the keystroke
    /// that triggered it is replayed there, so nothing typed is lost (and input methods still work).
    private func beginTypeToSearch(with event: NSEvent) {
        guard panel.makeFirstResponder(searchOverlay.field),
              let editor = searchOverlay.field.currentEditor() else { return }
        // Focusing a text field selects its contents; put the caret at the end so the new
        // keystroke adds to any existing query instead of replacing it.
        editor.selectedRange = NSRange(location: (editor.string as NSString).length, length: 0)
        editor.keyDown(with: event)
    }

    /// Escape pressed while the search field itself has focus: first clear the query (and hand
    /// focus back to the list so arrow keys resume browsing), then a second Escape closes the panel.
    private func handleSearchFieldEscape() {
        if imagePreview.isVisible {
            imagePreview.hide()
        } else if searchOverlay.field.stringValue.isEmpty {
            hide()
        } else {
            searchOverlay.reset()
            filterDidChange()
            focusCardList()
        }
    }

    private func handleEscape() {
        if imagePreview.isVisible {
            imagePreview.hide()
        } else if focusedRow == .saved {
            collapseSavedRow()
        } else if !searchOverlay.field.stringValue.isEmpty {
            searchOverlay.reset()
            filterDidChange()
        } else {
            hide()
        }
    }

    // MARK: - Context menu

    /// Right-click menu for the focused card. The card was selected just before this is built, so
    /// every action simply operates on `focusedItem`.
    private func contextMenu(for item: ClipboardItem) -> NSMenu {
        let menu = NSMenu()
        func add(_ title: String, _ action: Selector, key: String = "", modifiers: NSEvent.ModifierFlags = []) {
            let menuItem = NSMenuItem(title: title, action: action, keyEquivalent: key)
            menuItem.keyEquivalentModifierMask = modifiers
            menuItem.target = self
            menu.addItem(menuItem)
        }

        let isText = item.type != .image
        if DirectPaste.isActive, !spaceChangedSinceShow, let appName = previousActiveApp?.localizedName {
            add("Paste to \(appName)", #selector(menuPaste), key: "\r")
            if isText { add("Paste as Plain Text", #selector(menuPastePlain), key: "\r", modifiers: .shift) }
            add("Copy", #selector(menuCopy), key: "c", modifiers: .command)
        } else {
            add("Copy", #selector(menuPaste), key: "\r")
            if isText { add("Copy as Plain Text", #selector(menuPastePlain), key: "\r", modifiers: .shift) }
        }

        menu.addItem(.separator())
        if focusedRow == .history {
            add("Save", #selector(menuSave), key: "s", modifiers: .command)
        }
        if item.type == .url {
            add("Open Link", #selector(menuOpenLink), key: "\r", modifiers: .command)
        }
        add("Preview", #selector(menuPreview), key: " ")

        menu.addItem(.separator())
        add("Delete", #selector(menuDelete), key: "\u{8}")
        return menu
    }

    @objc private func menuPaste() { selectCurrent() }
    @objc private func menuPastePlain() { selectCurrent(plainText: true) }
    @objc private func menuCopy() { selectCurrent(copyOnly: true) }
    @objc private func menuSave() { saveCurrentToSaved() }
    @objc private func menuOpenLink() { openLinkIfCurrentIsURL() }
    @objc private func menuPreview() { togglePreview() }
    @objc private func menuDelete() { handleDelete() }
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
            cell.configure(with: item, highlighted: focusedRow == .history && indexPath.item == selectedIndex)
            cell.view.isHidden = item.id == draggedItemID // the dragged item's slot shows as a gap

            let number = indexPath.item - quickPasteBaseIndex() + 1
            let showBadge = commandHeld && focusedRow == .history && (1...9).contains(number)
            cell.setQuickPasteNumber(showBadge ? number : nil)
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
        setSelectedIndex(indexPath.item)
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

    /// Reordering is only well-defined against the unfiltered list, so it's disabled while a
    /// search or type filter is active.
    func collectionView(_ collectionView: NSCollectionView, pasteboardWriterForItemAt indexPath: IndexPath) -> NSPasteboardWriting? {
        guard !isFiltering else { return nil }
        let pasteboardItem = NSPasteboardItem()
        pasteboardItem.setString(String(indexPath.item), forType: Self.reorderPasteboardType)
        return pasteboardItem
    }

    func collectionView(
        _ collectionView: NSCollectionView, validateDrop draggingInfo: NSDraggingInfo,
        proposedIndexPath proposedDropIndexPath: AutoreleasingUnsafeMutablePointer<NSIndexPath>,
        dropOperation proposedDropOperation: UnsafeMutablePointer<NSCollectionView.DropOperation>
    ) -> NSDragOperation {
        guard !isFiltering, let draggedItemID,
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
