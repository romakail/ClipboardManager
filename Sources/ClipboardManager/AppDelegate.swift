import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var store: HistoryStore!
    private var monitor: ClipboardMonitor!
    private var hotKeyManager: HotKeyManager!
    private var panelController: HistoryPanelController!

    private let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        store = HistoryStore()
        panelController = HistoryPanelController(store: store)

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

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: "Clipboard History")
        }

        let menu = NSMenu()
        let openItem = NSMenuItem(title: "Open History (⇧⌘V)", action: #selector(openHistory), keyEquivalent: "")
        openItem.target = self
        menu.addItem(openItem)

        menu.addItem(.separator())

        launchAtLoginItem.target = self
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(.separator())

        let quitItem = NSMenuItem(title: "Quit ClipboardManager", action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    @objc private func openHistory() {
        panelController.toggle()
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
        launchAtLoginItem.state = isLaunchAtLoginEnabled ? .on : .off
    }
}
