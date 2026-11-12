import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private var statusItem: NSStatusItem!
    private var store: HistoryStore!
    private var savedStore: SavedStore!
    private var monitor: ClipboardMonitor!
    private var hotKeyManager: HotKeyManager!
    private var panelController: HistoryPanelController!

    private let pauseItem = NSMenuItem(title: "Pause Capturing", action: #selector(togglePause), keyEquivalent: "")
    private let directPasteItem = NSMenuItem(title: "Paste Directly into Active App", action: #selector(toggleDirectPaste), keyEquivalent: "")
    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store = HistoryStore()
        savedStore = SavedStore()
        panelController = HistoryPanelController(store: store, savedStore: savedStore)

        monitor = ClipboardMonitor(store: store)
        monitor.start()

        hotKeyManager = HotKeyManager { [weak self] in
            // Deferred to the next run loop turn: manipulating window key/focus state
            // synchronously inside the Carbon hotkey callback doesn't reliably take effect
            // at the WindowServer level, which left the panel visible but not receiving keystrokes.
            DispatchQueue.main.async {
                self?.panelController.toggle()
            }
        }
        hotKeyManager.register()

        setupStatusItem()
    }

    /// Opening the app again while it's already running (Spotlight, Finder, `open`) has nothing
    /// else to show for it, so it brings up the history panel.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        panelController.show()
        return false
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        updateStatusIcon()

        let menu = NSMenu()
        menu.delegate = self

        let openItem = NSMenuItem(title: "Open History (⇧⌘V)", action: #selector(openHistory), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        for item in [pauseItem, directPasteItem, launchAtLoginItem] {
            item.target = self
            menu.addItem(item)
        }

        menu.addItem(.separator())

        let clearItem = NSMenuItem(title: "Clear History…", action: #selector(clearHistory), keyEquivalent: "")
        clearItem.target = self
        menu.addItem(clearItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit ClipboardManager", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    /// Checkmarks are refreshed each time the menu opens: Accessibility access in particular can
    /// be granted or revoked in System Settings while the app is running.
    func menuNeedsUpdate(_ menu: NSMenu) {
        pauseItem.state = monitor.isPaused ? .on : .off
        directPasteItem.state = DirectPaste.isActive ? .on : .off
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
    }

    private func updateStatusIcon() {
        let symbolName = monitor.isPaused ? "pause.circle" : "doc.on.clipboard"
        let description = monitor.isPaused ? "Clipboard History (paused)" : "Clipboard History"
        statusItem.button?.image = NSImage(systemSymbolName: symbolName, accessibilityDescription: description)
    }

    @objc private func openHistory() {
        panelController.toggle()
    }

    @objc private func togglePause() {
        monitor.isPaused.toggle()
        updateStatusIcon()
    }

    /// Direct paste needs Accessibility access. Until that's granted, choosing this asks for it
    /// (macOS shows its own prompt leading to System Settings) rather than flipping the setting.
    @objc private func toggleDirectPaste() {
        if DirectPaste.isTrusted {
            Preferences.directPaste.toggle()
        } else {
            Preferences.directPaste = true
            DirectPaste.requestAccess()
        }
    }

    @objc private func clearHistory() {
        let alert = NSAlert()
        alert.messageText = "Clear your clipboard history?"
        alert.informativeText = "All \(store.items.count) history items will be deleted. Saved items are kept. This can't be undone."
        alert.alertStyle = .warning
        alert.addButton(withTitle: "Clear History")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true

        NSApp.activate(ignoringOtherApps: true)
        if alert.runModal() == .alertFirstButtonReturn {
            store.removeAll()
        }
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }

    private var isLaunchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if isLaunchAtLoginEnabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("Failed to toggle launch at login: \(error)")
        }
    }
}
