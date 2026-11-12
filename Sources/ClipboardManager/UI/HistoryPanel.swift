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

/// Content view that catches keyboard input for the panel.
///
/// Everything is matched by physical key position (keyCode), not the layout-translated character:
/// with a non-Latin input source (e.g. Russian) `charactersIgnoringModifiers` returns the Cyrillic
/// letter under that key, not "f"/"s", so a characters-based check silently never matches.
final class KeyCatchingView: StyledView {
    var onLeftArrow: (() -> Void)?
    var onRightArrow: (() -> Void)?
    var onDownArrow: (() -> Void)?
    var onUpArrow: (() -> Void)?
    var onEnter: (() -> Void)?
    var onShiftEnter: (() -> Void)?
    var onSpace: (() -> Void)?
    var onDelete: (() -> Void)?
    var onEscape: (() -> Void)?
    /// `backwards` is true for ⇧Tab.
    var onTab: ((_ backwards: Bool) -> Void)?
    var onCommandReturn: (() -> Void)?
    var onCommandS: (() -> Void)?
    var onCommandC: (() -> Void)?
    var onCommandDelete: (() -> Void)?
    var onFind: (() -> Void)?
    /// ⌘1…⌘9.
    var onQuickPaste: ((Int) -> Void)?
    var onCommandKeyChanged: ((_ isDown: Bool) -> Void)?
    /// A printable key pressed while the card list (not the search field) has focus.
    var onTypeToSearch: ((NSEvent) -> Void)?

    private static let digitKeys: [UInt16: Int] = [18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9]

    /// Standard editing shortcuts. A menu-bar-less app has no Edit menu to provide these, so
    /// without this ⌘V/⌘A/⌘C simply do nothing inside the search field.
    private static let editingKeys: [UInt16: Selector] = [
        0: #selector(NSText.selectAll(_:)),
        6: Selector(("undo:")),
        7: #selector(NSText.cut(_:)),
        8: #selector(NSText.copy(_:)),
        9: #selector(NSText.paste(_:)),
    ]

    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// ⌘-shortcuts are handled here rather than in keyDown so they also work while the search
    /// field has focus: key equivalents are offered to the whole view hierarchy first.
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
              event.modifierFlags.intersection([.command, .shift, .option, .control]) == .command else {
            return super.performKeyEquivalent(with: event)
        }

        if let editor = window?.firstResponder as? NSTextView, let selector = Self.editingKeys[event.keyCode] {
            // ⌘C with no text selected in the search field still means "copy the highlighted card".
            let copiesCard = event.keyCode == 8 && editor.selectedRange().length == 0
            if !copiesCard {
                return NSApp.sendAction(selector, to: nil, from: self)
            }
        }

        switch event.keyCode {
        case 3: onFind?() // F
        case 1: onCommandS?() // S
        case 8: onCommandC?() // C
        case 13: onEscape?() // W
        case 51: onCommandDelete?() // Delete / Backspace
        case 36, 76: onCommandReturn?() // Return / keypad enter
        default:
            guard let number = Self.digitKeys[event.keyCode] else {
                return super.performKeyEquivalent(with: event)
            }
            onQuickPaste?(number)
        }
        return true
    }

    override func flagsChanged(with event: NSEvent) {
        onCommandKeyChanged?(event.modifierFlags.contains(.command))
        super.flagsChanged(with: event)
    }

    override func keyDown(with event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

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
        case 48: // Tab
            onTab?(flags.contains(.shift))
        case 36, 76: // Return / keypad enter
            if flags.contains(.shift) {
                onShiftEnter?()
            } else {
                onEnter?()
            }
        default:
            if Self.isPrintable(event) {
                onTypeToSearch?(event)
            } else {
                super.keyDown(with: event)
            }
        }
    }

    private static func isPrintable(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection([.command, .control]).isEmpty,
              let scalar = event.characters?.unicodeScalars.first else { return false }
        // 0xF700–0xF8FF is where AppKit puts function/navigation keys.
        return !CharacterSet.controlCharacters.contains(scalar) && !(0xF700...0xF8FF).contains(scalar.value)
    }
}
