import AppKit

/// An always-visible search bar pinned to the top of the panel. Real keyboard focus (via
/// makeFirstResponder) is what makes typing/arrows/backspace work natively — no manual forwarding.
final class SearchOverlayView: NSView {
    let field = NSTextField(string: "")
    var onTextChange: ((String) -> Void)?
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?

    private let iconLabel = NSTextField(labelWithString: "🔍")
    private static let idleBorderColor = NSColor.separatorColor.withAlphaComponent(0.8).cgColor

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.textBackgroundColor.cgColor
        layer?.cornerRadius = 8
        layer?.borderWidth = 1
        layer?.borderColor = Self.idleBorderColor

        iconLabel.font = .systemFont(ofSize: 13)
        iconLabel.textColor = .secondaryLabelColor
        iconLabel.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iconLabel)

        field.placeholderString = "Search clipboard history…  (⌘F)"
        field.isBordered = false
        field.drawsBackground = false
        field.font = .systemFont(ofSize: 13)
        field.focusRingType = .none
        field.delegate = self
        field.translatesAutoresizingMaskIntoConstraints = false
        addSubview(field)

        NSLayoutConstraint.activate([
            iconLabel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 10),
            iconLabel.centerYAnchor.constraint(equalTo: centerYAnchor),

            field.leadingAnchor.constraint(equalTo: iconLabel.trailingAnchor, constant: 8),
            field.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -10),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func reset() {
        field.stringValue = ""
    }
}

extension SearchOverlayView: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        onTextChange?(field.stringValue)
    }

    func controlTextDidBeginEditing(_ obj: Notification) {
        layer?.borderColor = NSColor.controlAccentColor.cgColor
        layer?.borderWidth = 1.5
    }

    func controlTextDidEndEditing(_ obj: Notification) {
        layer?.borderColor = Self.idleBorderColor
        layer?.borderWidth = 1
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            onReturn?()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            onEscape?()
            return true
        }
        return false
    }
}
