import AppKit

/// A borderless, non-activating panel: it can become key (to receive keyboard input)
/// without becoming the frontmost application, so the previously-active app never loses focus.
final class HistoryPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    convenience init() {
        self.init(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 220),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle, .fullScreenAuxiliary]
        isReleasedWhenClosed = false
    }
}

/// Content view that catches keyboard input for the panel: arrows, enter, space, cmd+return, ctrl+f, escape.
final class KeyCatchingView: NSView {
    var onLeftArrow: (() -> Void)?
    var onRightArrow: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onUpArrow: (() -> Void)?
    var onEnter: (() -> Void)?
    var onShiftEnter: (() -> Void)?
    var onSpace: (() -> Void)?
    var onDelete: (() -> Void)?
    var onCommandReturn: (() -> Void)?
    var onCommandS: (() -> Void)?
    var onFind: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Matched by physical key position (keyCode), not the layout-translated character: with a
        // non-Latin input source (e.g. Russian) charactersIgnoringModifiers returns the Cyrillic
        // letter under that key, not "f"/"s", so a characters-based check silently never matches.
        if flags == .command, event.keyCode == 3 { // F
            onFind?()
            return
        }
        if flags == .command, event.keyCode == 1 { // S
            onCommandS?()
            return
        }

        switch event.keyCode {
        case 123: // Left arrow
            onLeftArrow?()
        case 124: // Right arrow
            onRightArrow?()
        case 125: // Down arrow
            onDownArrow?()
        case 126: // Up arrow
            onUpArrow?()
        case 53: // Escape
            onEscape?()
        case 49: // Space
            onSpace?()
        case 51: // Delete / Backspace
            onDelete?()
        case 36, 76: // Return / keypad enter
            if flags.contains(.command) {
                onCommandReturn?()
            } else if flags.contains(.shift) {
                onShiftEnter?()
            } else {
                onEnter?()
            }
        default:
            super.keyDown(with: event)
        }
    }
}
