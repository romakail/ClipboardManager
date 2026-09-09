import AppKit

final class HistoryItemView: NSCollectionViewItem {
    static let identifier = NSUserInterfaceItemIdentifier("HistoryItemView")
    static let cardSize = NSSize(width: 196, height: 173) // base 170x150, +15%
    private static let headerHeight: CGFloat = cardSize.height / 5

    private let cardView = NSView()
    private let headerView = NSView()
    private let typeLabel = NSTextField(labelWithString: "")
    private let appIconView = NSImageView()
    private let thumbnailView = NSImageView()
    private let textLabel = NSTextField(wrappingLabelWithString: "")
    private let timestampLabel = NSTextField(labelWithString: "")

    private static let defaultBorderColor = NSColor.separatorColor.withAlphaComponent(0.9).cgColor
    private static let defaultBackgroundColor = NSColor.textBackgroundColor.cgColor
    private static let defaultHeaderColor = NSColor.secondaryLabelColor.withAlphaComponent(0.35)

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter
    }()

    override func loadView() {
        view = NSView(frame: NSRect(origin: .zero, size: Self.cardSize))
        view.wantsLayer = true

        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = 10
        cardView.layer?.masksToBounds = true
        cardView.layer?.backgroundColor = Self.defaultBackgroundColor
        cardView.layer?.borderWidth = 1
        cardView.layer?.borderColor = Self.defaultBorderColor
        cardView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(cardView)

        // Header: item type on the left, source-app icon on the right, tinted to the app's color.
        headerView.wantsLayer = true
        headerView.layer?.backgroundColor = Self.defaultHeaderColor.cgColor
        headerView.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(headerView)

        typeLabel.font = .systemFont(ofSize: 11, weight: .semibold)
        typeLabel.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(typeLabel)

        appIconView.imageScaling = .scaleProportionallyUpOrDown
        appIconView.translatesAutoresizingMaskIntoConstraints = false
        headerView.addSubview(appIconView)

        // Content: thumbnail (images) or wrapping text (text/links) — only one visible at a time.
        thumbnailView.imageScaling = .scaleProportionallyUpOrDown
        thumbnailView.translatesAutoresizingMaskIntoConstraints = false
        // The image's own intrinsic size must never be allowed to fight the fixed frame below —
        // without this, some image dimensions pushed the view past its bottom constraint and
        // covered the timestamp.
        thumbnailView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        thumbnailView.setContentHuggingPriority(.defaultLow, for: .vertical)
        thumbnailView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        thumbnailView.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1), for: .vertical)
        cardView.addSubview(thumbnailView)

        textLabel.font = .systemFont(ofSize: 12)
        textLabel.textColor = .labelColor
        textLabel.maximumNumberOfLines = 0
        textLabel.lineBreakMode = .byWordWrapping
        textLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(textLabel)

        // Timestamp: always bottom-right of the card, independent of content type/length. Given
        // its own opaque backing (and added last, so it's frontmost) so it stays legible no
        // matter what sits underneath it.
        timestampLabel.font = .systemFont(ofSize: 10)
        timestampLabel.textColor = .secondaryLabelColor
        timestampLabel.alignment = .right
        timestampLabel.wantsLayer = true
        timestampLabel.layer?.cornerRadius = 4
        timestampLabel.translatesAutoresizingMaskIntoConstraints = false
        cardView.addSubview(timestampLabel)

        NSLayoutConstraint.activate([
            cardView.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 5),
            cardView.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -5),
            cardView.topAnchor.constraint(equalTo: view.topAnchor, constant: 5),
            cardView.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -5),

            headerView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor),
            headerView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor),
            headerView.topAnchor.constraint(equalTo: cardView.topAnchor),
            headerView.heightAnchor.constraint(equalToConstant: Self.headerHeight),

            appIconView.trailingAnchor.constraint(equalTo: headerView.trailingAnchor, constant: -8),
            appIconView.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),
            appIconView.widthAnchor.constraint(equalToConstant: 18),
            appIconView.heightAnchor.constraint(equalToConstant: 18),

            typeLabel.leadingAnchor.constraint(equalTo: headerView.leadingAnchor, constant: 10),
            typeLabel.trailingAnchor.constraint(lessThanOrEqualTo: appIconView.leadingAnchor, constant: -6),
            typeLabel.centerYAnchor.constraint(equalTo: headerView.centerYAnchor),

            thumbnailView.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 8),
            thumbnailView.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 8),
            thumbnailView.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -8),
            thumbnailView.bottomAnchor.constraint(equalTo: timestampLabel.topAnchor, constant: -4),

            textLabel.topAnchor.constraint(equalTo: headerView.bottomAnchor, constant: 8),
            textLabel.leadingAnchor.constraint(equalTo: cardView.leadingAnchor, constant: 10),
            textLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -10),
            textLabel.bottomAnchor.constraint(lessThanOrEqualTo: timestampLabel.topAnchor, constant: -4),

            timestampLabel.leadingAnchor.constraint(greaterThanOrEqualTo: cardView.leadingAnchor, constant: 10),
            timestampLabel.trailingAnchor.constraint(equalTo: cardView.trailingAnchor, constant: -10),
            timestampLabel.bottomAnchor.constraint(equalTo: cardView.bottomAnchor, constant: -6),
        ])
    }

    func configure(with item: ClipboardItem, highlighted: Bool) {
        timestampLabel.stringValue = " " + Self.timeFormatter.string(from: item.timestamp) + " "
        timestampLabel.layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.92).cgColor
        typeLabel.stringValue = item.typeLabelText

        switch item.type {
        case .image:
            thumbnailView.isHidden = false
            textLabel.isHidden = true
            textLabel.stringValue = "" // clear stale content from cell reuse
            thumbnailView.image = item.imageFileName.flatMap(ImageStore.loadImage(fileName:))
        case .url, .text:
            thumbnailView.isHidden = true
            textLabel.isHidden = false
            thumbnailView.image = nil // clear stale content from cell reuse
            textLabel.stringValue = item.previewText
        }

        let resolvedApp = AppIconResolver.resolve(bundleID: item.sourceAppBundleID)
        let headerColor = resolvedApp?.tint ?? AppIconResolver.defaultTint
        headerView.layer?.backgroundColor = headerColor.withAlphaComponent(0.85).cgColor
        appIconView.image = resolvedApp?.icon ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "Unknown app")
        appIconView.contentTintColor = resolvedApp == nil ? .white : nil

        let textColor = Self.contrastingTextColor(for: headerColor)
        typeLabel.textColor = textColor

        cardView.layer?.borderColor = highlighted ? NSColor.controlAccentColor.cgColor : Self.defaultBorderColor
        cardView.layer?.borderWidth = highlighted ? 2.5 : 1
        cardView.layer?.backgroundColor = highlighted
            ? NSColor.controlAccentColor.withAlphaComponent(0.12).cgColor
            : Self.defaultBackgroundColor
        cardView.layer?.shadowColor = NSColor.controlAccentColor.cgColor
        cardView.layer?.shadowOpacity = highlighted ? 0.5 : 0
        cardView.layer?.shadowRadius = 6
        cardView.layer?.shadowOffset = .zero
    }

    private static func contrastingTextColor(for background: NSColor) -> NSColor {
        guard let rgb = background.usingColorSpace(.deviceRGB) else { return .white }
        let brightness = (0.299 * rgb.redComponent) + (0.587 * rgb.greenComponent) + (0.114 * rgb.blueComponent)
        return brightness > 0.6 ? .black : .white
    }

    /// A brief fade-in + accent glow pulse, played when this card represents a freshly-copied item.
    func playInsertionAnimation() {
        guard let layer = cardView.layer else { return }

        view.alphaValue = 0
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.3
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            view.animator().alphaValue = 1
        }

        let settledColor = layer.borderColor
        let settledWidth = layer.borderWidth
        layer.borderColor = NSColor.controlAccentColor.cgColor
        layer.borderWidth = 3
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.5)
            layer.borderColor = settledColor
            layer.borderWidth = settledWidth
            CATransaction.commit()
        }
    }
}
