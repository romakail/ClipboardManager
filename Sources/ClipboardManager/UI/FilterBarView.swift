import AppKit

/// The row of type chips (All / Text / Links / Images / Colors) at the left of the top bar.
final class FilterBarView: NSView {
    var onChange: ((HistoryFilter) -> Void)?
    private(set) var selected: HistoryFilter = .all

    private let chips: [FilterChip] = HistoryFilter.allCases.map { FilterChip(filter: $0) }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)

        let stack = NSStackView(views: chips)
        stack.orientation = .horizontal
        stack.spacing = 2
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])

        for chip in chips {
            chip.onClick = { [weak self] filter in self?.select(filter, notify: true) }
        }
        refreshChips()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func select(_ filter: HistoryFilter, notify: Bool) {
        guard filter != selected else { return }
        selected = filter
        refreshChips()
        if notify { onChange?(filter) }
    }

    /// Tab / ⇧Tab: steps to the neighbouring chip, wrapping around.
    func cycle(by delta: Int) {
        let all = HistoryFilter.allCases
        let next = (selected.rawValue + delta + all.count) % all.count
        select(all[next], notify: true)
    }

    private func refreshChips() {
        for chip in chips {
            chip.isSelected = chip.filter == selected
        }
    }
}

private final class FilterChip: StyledView {
    let filter: HistoryFilter
    var onClick: ((HistoryFilter) -> Void)?
    var isSelected = false { didSet { applyState() } }

    private let label = NSTextField(labelWithString: "")

    init(filter: HistoryFilter) {
        self.filter = filter
        super.init(frame: .zero)
        cornerRadius = 12
        translatesAutoresizingMaskIntoConstraints = false

        label.stringValue = filter.title
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: 24),
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 11),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -11),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
        applyState()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func applyState() {
        fillColor = isSelected ? NSColor.labelColor.withAlphaComponent(0.13) : nil
        label.font = .systemFont(ofSize: 12, weight: isSelected ? .semibold : .regular)
        label.textColor = isSelected ? .labelColor : .secondaryLabelColor
    }

    override func mouseDown(with event: NSEvent) {
        onClick?(filter)
    }
}
