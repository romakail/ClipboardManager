import AppKit

/// One clipboard card: a header tinted with the source app's color (type, age, app icon), a body
/// that depends on the kind of content, and a caption line along the bottom.
final class HistoryItemView: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryItemView")
    static let cardSize = NSSize(width: 208, height: 192)

    /// Space between the collection slot and the card, which is where the selection ring sits.
    private static let slotInset: CGFloat = 5
    private static let cornerRadius: CGFloat = 12
    private static let headerHeight: CGFloat = 42
    private static let footerHeight: CGFloat = 24
    private static let maxBodyLines = 7

    private let ringView = StyledView()
    private let shadowView = StyledView()
    private let cardView = StyledView()
    private let headerView = StyledView()
    private let typeLabel = NSTextField(labelWithString: "")
    private let timeLabel = NSTextField(labelWithString: "")
    private let appIconView = NSImageView()
    private let bodyView = StyledView()
    private let thumbnailView = NSImageView()
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let swatchLabel = NSTextField(labelWithString: "")
    private let metaLabel = NSTextField(labelWithString: "")
    private let badgeView = StyledView()
    private let badgeLabel = NSTextField(labelWithString: "")

    private var isHighlightedCard = false

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.cardSize))
        view.wantsLayer = true

        // Selection ring: drawn around the card with a hairline gap, rather than as the card's
        // own border, so it never covers content.
        ringView.cornerRadius = Self.cornerRadius + Self.slotInset - 1
        ringView.strokeColor = .controlAccentColor
        ringView.strokeWidth = 3
        ringView.isHidden = true
        ringView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(ringView)

        // The card clips its content to rounded corners, which would also clip a shadow — so the
        // shadow comes from an identical shape sitting right behind it.
        shadowView.cornerRadius = Self.cornerRadius
        shadowView.fillColor = .textBackgroundColor
        let shadow = NSShadow()
        shadow.shadowColor = NSColor.black.withAlphaComponent(0.22)
        shadow.shadowBlurRadius = 5
        shadow.shadowOffset = NSSize(width: 0, height: -1.5)
        shadowView.shadow = shadow
        shadowView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(shadowView)

        cardView.cornerRadius = Self.cornerRadius
        cardView.clipsContent = true
        cardView.fillColor = .textBackgroundColor
        cardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardView)

        headerView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(headerView)

        typeLabel.font = .systemFont(ofSize: 12.5, weight: .semibold)
        typeLabel.lineBreakMode = .byTruncatingTail
        typeLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(typeLabel)

        timeLabel.font = .systemFont(ofSize: 10.5)
        timeLabel.lineBreakMode = .byTruncatingTail
        timeLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(timeLabel)

        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(appIconView)

        bodyView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(bodyView)

        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        // The image's intrinsic size must never fight the fixed frame below, or large images
        // push the view past its constraints.
        thumbnailView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        thumbnailView.setContentHuggingPriority(.defaultLow, for: .vertical)
        thumbnailView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        thumbnailView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        bodyView.addSubview(thumbnailView)

        textLabel.font = .systemFont(ofSize: 12)
        textLabel.maximumNumberOfLines = Self.maxBodyLines
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.cell?.truncatesLastVisibleLine = true
        textLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyView.addSubview(textLabel)

        swatchLabel.font = .monospacedSystemFont(ofSize: 17, weight: .semibold)
        swatchLabel.alignment = .center
        swatchLabel.translatesAutoresizingMaskIntoConstraints = false
        bodyView.addSubview(swatchLabel)

        metaLabel.font = .systemFont(ofSize: 10.5)
        metaLabel.lineBreakMode = .byTruncatingMiddle
        metaLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        metaLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(metaLabel)

        // Quick-paste hint ("⌘3"), shown only while ⌘ is held.
        badgeView.cornerRadius = 5
        badgeView.fillColor = .controlAccentColor
        badgeView.isHidden = true
        badgeView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(badgeView)

        badgeLabel.font = .monospacedDigitSystemFont(ofSize: 10.5, weight: .semibold)
        badgeLabel.textColor = .white
        badgeLabel.translatesAutoresizingMaskIntoConstraints = false
        badgeView.addSubview(badgeLabel)

        let inset = Self.slotInset
        NSLayoutConstraint.activate([
            ringView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 1),
            ringView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -1),
            ringView.topAnchor.constraint(equalTo: view.topAnchor, constant: 1),
            ringView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -1),

            cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: inset),
            cardView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -inset),
            cardView.topAnchor.constraint(equalTo: view.topAnchor, constant: inset),
            cardView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -inset),

            shadowView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            shadowView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            shadowView.topAnchor.constraint(equalTo: cardView.topAnchor),
            shadowView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            headerView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: cardView.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            appIconView.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            appIconView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 30),
            appIconView.heightAnchor.constraint(equalToConstant: 30),

            typeLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 11),
            typeLabel.trailingAnchor.constraint(lessThanOrEqualTo: appIconView.leadingAnchor, constant: -6),
            typeLabel.topAnchor.constraint(equalTo: headerView.topAnchor, constant: 6),

            timeLabel.leadingAnchor.constraint(equalTo: typeLabel.leadingAnchor),
            timeLabel.trailingAnchor.constraint(lessThanOrEqualTo: appIconView.leadingAnchor, constant: -6),
            timeLabel.topAnchor.constraint(equalTo: typeLabel.bottomAnchor, constant: 1),

            bodyView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            bodyView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            bodyView.topAnchor.constraint(equalTo: headerView.bottomAnchor),
            bodyView.bottomAnchor.constraint(equalTo: cardView.bottomAnchor),

            thumbnailView.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor, constant: 6),
            thumbnailView.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor, constant: -6),
            thumbnailView.topAnchor.constraint(equalTo: bodyView.topAnchor, constant: 6),
            thumbnailView.bottomAnchor.constraint(equalTo: bodyView.bottomAnchor, constant: -Self.footerHeight),

            textLabel.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor, constant: 11),
            textLabel.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor, constant: -11),
            textLabel.topAnchor.constraint(equalTo: bodyView.topAnchor, constant: 8),
            textLabel.bottomAnchor.constraint(lessThanOrEqualTo: bodyView.bottomAnchor, constant: -Self.footerHeight),

            swatchLabel.leadingAnchor.constraint(equalTo: bodyView.leadingAnchor, constant: 8),
            swatchLabel.trailingAnchor.constraint(equalTo: bodyView.trailingAnchor, constant: -8),
            swatchLabel.centerYAnchor.constraint(equalTo: bodyView.centerYAnchor, constant: -4),

            metaLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 11),
            metaLabel.trailingAnchor.constraint(lessThanOrEqualTo: badgeView.leadingAnchor, constant: -6),
            metaLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -7),

            badgeView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -8),
            badgeView.centerYAnchor.constraint(equalTo: metaLabel.centerYAnchor),
            badgeView.heightAnchor.constraint(equalToConstant: 17),

            badgeLabel.leadingAnchor.constraint(equalTo: badgeView.leadingAnchor, constant: 5),
            badgeLabel.trailingAnchor.constraint(equalTo: badgeView.trailingAnchor, constant: -5),
            badgeLabel.centerYAnchor.constraint(equalTo: badgeView.centerYAnchor),
        ])
    }

    override func prepareForReuse() {
        super.prepareForReuse()
        view.alphaValue = 1
        ringView.alphaValue = 1
        setQuickPasteNumber(nil)
    }

    func configure(with item: ClipboardItem, highlighted: Bool) {
        let kind = item.kind
        let resolvedApp = AppIconResolver.resolve(bundleID: item.sourceAppBundleID)

        let headerColor = resolvedApp?.tint ?? Self.fallbackTint(for: kind)
        let headerTextColor = headerColor.contrastingLabelColor
        headerView.fillColor = headerColor
        typeLabel.stringValue = item.displayTitle
        typeLabel.textColor = headerTextColor
        timeLabel.stringValue = item.relativeTimeText
        timeLabel.textColor = headerTextColor.withAlphaComponent(0.78)
        appIconView.image = resolvedApp?.icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "Unknown app")
        appIconView.contentTintColor = resolvedApp == nil ? headerTextColor : nil

        // Reset everything a reused cell might still be showing, then fill in this item's kind.
        thumbnailView.isHidden = true
        thumbnailView.image = nil
        textLabel.isHidden = true
        textLabel.stringValue = ""
        swatchLabel.isHidden = true
        bodyView.fillColor = nil
        metaLabel.textColor = .secondaryLabelColor
        metaLabel.stringValue = item.metaText

        switch kind {
        case .image:
            thumbnailView.isHidden = false
            if let thumbnail = item.imageFileName.flatMap({ ImageStore.thumbnail(fileName: $0) }) {
                thumbnailView.image = thumbnail.image
                metaLabel.stringValue = "\(Int(thumbnail.pixelSize.width)) × \(Int(thumbnail.pixelSize.height))"
            }
        case .text:
            textLabel.isHidden = false
            textLabel.textColor = .labelColor
            textLabel.stringValue = item.bodyPreview
        case .link:
            textLabel.isHidden = false
            textLabel.textColor = .linkColor
            textLabel.stringValue = item.bodyPreview
        case .color:
            let color = item.parsedColor ?? .gray
            let onColor = color.contrastingLabelColor
            bodyView.fillColor = color
            swatchLabel.isHidden = false
            swatchLabel.stringValue = item.metaText
            swatchLabel.textColor = onColor
            metaLabel.textColor = onColor.withAlphaComponent(0.7)
            metaLabel.stringValue = Self.rgbDescription(of: color)
        }

        setHighlighted(highlighted)
    }

    func setHighlighted(_ highlighted: Bool) {
        isHighlightedCard = highlighted
        ringView.isHidden = !highlighted
    }

    /// Shows "⌘n" in the card's corner, or hides the badge for nil.
    func setQuickPasteNumber(_ number: Int?) {
        badgeView.isHidden = number == nil
        if let number {
            badgeLabel.stringValue = "⌘\(number)"
        }
    }

    /// A brief fade-in plus a flash of the selection ring, played when this card represents a
    /// freshly-copied (or freshly-saved) item.
    func playInsertionAnimation() {
        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
        }

        guard !isHighlightedCard else { return }
        ringView.alphaValue = 1
        ringView.isHidden = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self else { return }
            NSAnimationContext.runAnimationGroup({ context in
                context.duration = 0.5
                self.ringView.animator().alphaValue = 0
            }, completionHandler: {
                self.ringView.isHidden = !self.isHighlightedCard
                self.ringView.alphaValue = 1
            })
        }
    }

    /// Header color for items whose source app is unknown.
    private static func fallbackTint(for kind: ItemKind) -> NSColor {
        switch kind {
        case .text: return NSColor(srgbRed: 0.36, green: 0.42, blue: 0.52, alpha: 1)
        case .link: return NSColor(srgbRed: 0.16, green: 0.47, blue: 0.86, alpha: 1)
        case .image: return NSColor(srgbRed: 0.52, green: 0.36, blue: 0.78, alpha: 1)
        case .color: return NSColor(srgbRed: 0.30, green: 0.30, blue: 0.33, alpha: 1)
        }
    }

    private static func rgbDescription(of color: NSColor) -> String {
        guard let rgb = color.usingColorSpace(.sRGB) else { return "" }
        let channels = [rgb.redComponent, rgb.greenComponent, rgb.blueComponent].map { Int(($0 * 255).rounded()) }
        return "RGB \(channels[0]) \(channels[1]) \(channels[2])"
    }
}
