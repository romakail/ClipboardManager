import AppKit
import ApplicationServices
import Carbon.HIToolbox

enum Preferences {
    private static let directPasteKey = "directPasteEnabled"

    /// Whether choosing an item should also paste it into the app you came from. Only takes
    /// effect once Accessibility access has been granted; until then items are just copied.
    static var directPaste: Bool {
        get { UserDefaults.standard.object(forKey: directPasteKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: directPasteKey) }
    }
}

/// Pastes into another app by synthesising ⌘V, which macOS only allows for apps the user has
/// granted Accessibility access.
enum DirectPaste {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// True when choosing an item will really paste it, not just copy it.
    static var isActive: Bool {
        Preferences.directPaste && isTrusted
    }

    /// Shows the system prompt that deep-links to Privacy & Security → Accessibility.
    static func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    /// Sends ⌘V once `app` is frontmost. Activation is asynchronous, so posting immediately would
    /// deliver the keystroke to whichever app is still in front. If `app` never comes forward the
    /// keystroke is dropped — the item is on the pasteboard either way.
    static func paste(into app: NSRunningApplication) {
        waitUntilActive(app, attemptsLeft: 30)
    }

    private static func waitUntilActive(_ app: NSRunningApplication, attemptsLeft: Int) {
        if app.isActive {
            // One more beat so the app's key window is ready to receive the keystroke.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { postCommandV() }
            return
        }
        guard attemptsLeft > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
            waitUntilActive(app, attemptsLeft: attemptsLeft - 1)
        }
    }

    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Keeps physically-held keys (e.g. ⇧ from ⇧↩) from merging into the synthetic keystroke.
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        let keyCode = CGKeyCode(kVK_ANSI_V)
        let keyDown = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: true)
        let keyUp = CGEvent(keyboardEventSource: source, virtualKey: keyCode, keyDown: false)
        keyDown?.flags = .maskCommand
        keyUp?.flags = .maskCommand
        keyDown?.post(tap: .cgSessionEventTap)
        keyUp?.post(tap: .cgSessionEventTap)
    }
}
