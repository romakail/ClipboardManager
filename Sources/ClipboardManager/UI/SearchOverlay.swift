import AppKit

/// The search field in the top bar. Real keyboard focus (via makeFirstResponder) is what makes
/// typing, IME input and ⌘V work natively. Keys that mean "navigate the cards" — arrows, Tab,
/// Return, Escape — are intercepted and handed back to the panel, so the list stays fully
/// drivable while a query is being typed.
final class SearchOverlayView: StyledView {
    let field = NSTextField(string: "")
    var onTextChange: ((String) -> Void)?
    /// `shift` is true for ⇧Return (paste as plain text).
    var onReturn: ((_ shift: Bool) -> Void)?
    var onEscape: (() -> Void)?
    /// -1 for Left, +1 for Right.
    var onHorizontalArrow: ((Int) -> Void)?
    /// -1 for Up, +1 for Down.
    var onVerticalArrow: ((Int) -> Void)?
    var onTab: ((_ backwards: Bool) -> Void)?
    /// Backspace pressed with nothing left to delete.
    var onBackspaceWhenEmpty: (() -> Void)?

    private let iconView = NSImageView()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        cornerRadius = 8
        fillColor = NSColor.labelColor.withAlphaComponent(0.07)
        strokeColor = NSColor.labelColor.withAlphaComponent(0.1)
        strokeWidth = 1

        iconView.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "Search")
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 12, weight: .medium)
        iconView.contentTintColor = .secondaryLabelColor
        iconView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconView)

        field.placeholderString = "Type to search"
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.lineBreakMode = .byTruncatingTail
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        NSLayoutConstraint.activate([
            iconView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 9),
            iconView.centerYAnchor.constraint(equalTo: centerYAnchor),
            iconView.widthAnchor.constraint(equalToConstant: 16),

            field.leadingAnchor.constraint(equalTo: iconView.trailingAnchor, constant: 5),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -9),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var query: String {
        field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func reset() {
        field.stringValue = ""
    }

    private func setFocused(_ focused: Bool) {
        strokeColor = focused ? .controlAccentColor : NSColor.labelColor.withAlphaComponent(0.1)
        strokeWidth = focused ? 1.5 : 1
    }
}

extension SearchOverlayView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onTextChange?(field.stringValue)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        setFocused(true)
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        setFocused(false)
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        switch commandSelector {
        // ⇧Return may arrive as any of these depending on the field editor's key bindings, so
        // the modifier is read off the event rather than the selector.
        case #selector(NSResponder.insertNewline(_:)),
             #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)),
             #selector(NSResponder.insertLineBreak(_:)):
            onReturn?(NSApp.currentEvent?.modifierFlags.contains(.shift) ?? false)
        case #selector(NSResponder.cancelOperation(_:)):
            onEscape?()
        case #selector(NSResponder.moveLeft(_:)):
            onHorizontalArrow?(-1)
        case #selector(NSResponder.moveRight(_:)):
            onHorizontalArrow?(1)
        case #selector(NSResponder.moveUp(_:)):
            onVerticalArrow?(-1)
        case #selector(NSResponder.moveDown(_:)):
            onVerticalArrow?(1)
        case #selector(NSResponder.insertTab(_:)):
            onTab?(false)
        case #selector(NSResponder.insertBacktab(_:)):
            onTab?(true)
        case #selector(NSResponder.deleteBackward(_:)):
            guard field.stringValue.isEmpty else { return false }
            onBackspaceWhenEmpty?()
        default:
            return false
        }
        return true
    }
}
