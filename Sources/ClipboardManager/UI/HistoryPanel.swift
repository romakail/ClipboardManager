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
    var onEnter: (() -> Void)?
    var onSpace: (() -> Void)?
    var onCommandReturn: (() -> Void)?
    var onFind: (() -> Void)?
    var onEscape: (() -> Void)?

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if flags == .command, event.charactersIgnoringModifiers?.lowercased() == "f" {
            onFind?()
            return
        }

        switch event.keyCode {
        case 123: // Left arrow
            onLeftArrow?()
        case 124: // Right arrow
            onRightArrow?()
        case 53: // Escape
            onEscape?()
        case 49: // Space
            onSpace?()
        case 36, 76: // Return / keypad enter
            if flags.contains(.command) {
                onCommandReturn?()
            } else {
                onEnter?()
            }
        default:
            super.keyDown(with: event)
        }
    }
}
