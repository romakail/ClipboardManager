import AppKit

/// Shared layout numbers for the panel and its card rows.
enum PanelMetrics {
    static let cornerRadius: CGFloat = 18
    static let screenMargin: CGFloat = 10
    static let topPadding: CGFloat = 10
    static let topBarHeight: CGFloat = 30
    static let bottomPadding: CGFloat = 4
    static let cardSpacing: CGFloat = 4
    static let rowInsets = NSEdgeInsets(top: 8, left: 12, bottom: 10, right: 12)

    static var rowHeight: CGFloat {
        HistoryItemView.cardSize.height + rowInsets.top + rowInsets.bottom
    }

    static var baseHeight: CGFloat {
        topPadding + topBarHeight + 2 + rowHeight + bottomPadding
    }
}

/// A layer-backed view whose colors are plain NSColors re-resolved in `updateLayer`, so dynamic
/// system colors follow light/dark mode instead of being frozen as a CGColor at setup time.
class StyledView: NSView {
    var fillColor: NSColor? { didSet { needsDisplay = true } }
    var strokeColor: NSColor? { didSet { needsDisplay = true } }
    var strokeWidth: CGFloat = 0 { didSet { needsDisplay = true } }
    var cornerRadius: CGFloat = 0 { didSet { needsDisplay = true } }
    var clipsContent = false { didSet { needsDisplay = true } }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        guard let layer else { return }
        layer.backgroundColor = fillColor?.cgColor
        layer.borderColor = strokeColor?.cgColor
        layer.borderWidth = strokeWidth
        layer.cornerRadius = cornerRadius
        layer.cornerCurve = .continuous
        layer.masksToBounds = clipsContent
    }
}

enum Styling {
    /// A stretchable rounded-rect mask. NSVisualEffectView's behind-window blur isn't clipped by an
    /// ancestor layer's corner radius, so the rounding has to be applied through `maskImage`.
    static func roundedMask(radius: CGFloat) -> NSImage {
        let edge = radius * 2 + 1
        let image = NSImage(size: NSSize(width: edge, height: edge), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        image.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        image.resizingMode = .stretch
        return image
    }
}

extension NSColor {
    /// Black or white, whichever reads better on top of this color.
    var contrastingLabelColor: NSColor {
        guard let rgb = usingColorSpace(.sRGB) else { return .white }
        let luminance = (0.299 * rgb.redComponent) + (0.587 * rgb.greenComponent) + (0.114 * rgb.blueComponent)
        return luminance > 0.62 ? .black : .white
    }

    /// Parses `#RGB`, `#RRGGBB` and `#RRGGBBAA`. The leading `#` is required: bare hex is too easy
    /// to confuse with an ordinary word or id.
    static func fromHexString(_ string: String) -> NSColor? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("#") else { return nil }
        var digits = String(trimmed.dropFirst())
        guard [3, 6, 8].contains(digits.count), digits.allSatisfy(\.isHexDigit) else { return nil }
        if digits.count == 3 {
            digits = digits.map { "\($0)\($0)" }.joined()
        }
        guard let value = UInt64(digits, radix: 16) else { return nil }

        let hasAlpha = digits.count == 8
        let red = CGFloat((value >> (hasAlpha ? 24 : 16)) & 0xFF) / 255
        let green = CGFloat((value >> (hasAlpha ? 16 : 8)) & 0xFF) / 255
        let blue = CGFloat((value >> (hasAlpha ? 8 : 0)) & 0xFF) / 255
        let alpha = hasAlpha ? CGFloat(value & 0xFF) / 255 : 1
        return NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
    }
}

/// A row's scroll view only scrolls sideways, so an ordinary mouse wheel (vertical deltas only)
/// would do nothing. Vertical-dominant scrolls are re-issued as horizontal ones.
final class HorizontalScrollView: NSScrollView {
    override func scrollWheel(with event: NSEvent) {
        guard abs(event.scrollingDeltaY) > abs(event.scrollingDeltaX),
              let converted = Self.horizontalCopy(of: event) else {
            super.scrollWheel(with: event)
            return
        }
        super.scrollWheel(with: converted)
    }

    private static func horizontalCopy(of event: NSEvent) -> NSEvent? {
        guard let cgEvent = event.cgEvent?.copy() else { return nil }
        let delta = cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1)
        let fixed = cgEvent.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)
        let point = cgEvent.getIntegerValueField(.scrollWheelEventPointDeltaAxis1)

        // The line-delta fields are written first because setting them rewrites the derived ones.
        cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: 0)
        cgEvent.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: delta)
        cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0)
        cgEvent.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: fixed)
        cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: 0)
        cgEvent.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: point)
        return NSEvent(cgEvent: cgEvent)
    }
}

/// The collection view behind both card rows: shared layout, plus a right-click menu per card.
final class CardCollectionView: NSCollectionView {
    /// Asked for a context menu when a card is right-clicked.
    var menuProvider: ((IndexPath) -> NSMenu?)?

    func configureAsCardRow(in scrollView: NSScrollView, reorderType: NSPasteboard.PasteboardType) {
        let layout = NSCollectionViewFlowLayout()
        layout.scrollDirection = .horizontal
        layout.itemSize = HistoryItemView.cardSize
        layout.minimumInteritemSpacing = PanelMetrics.cardSpacing
        layout.minimumLineSpacing = PanelMetrics.cardSpacing
        layout.sectionInset = PanelMetrics.rowInsets
        collectionViewLayout = layout
        backgroundColors = [.clear]
        isSelectable = true
        register(HistoryItemView.self, forItemWithIdentifier: HistoryItemView.identifier)
        registerForDraggedTypes([reorderType])
        setDraggingSourceOperationMask(.move, forLocal: true)

        scrollView.documentView = self
        scrollView.hasHorizontalScroller = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false
        scrollView.translatesAutoresizingMaskIntoConstraints = false
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let point = convert(event.locationInWindow, from: nil)
        guard let indexPath = indexPathForItem(at: point) else { return nil }
        return menuProvider?(indexPath)
    }

    /// Scrolls just far enough to bring a card fully into view (with the row's side margin), so
    /// stepping through cards with the arrow keys doesn't re-centre the row on every press.
    /// Card frames are derived from the fixed layout metrics rather than asked of the layout,
    /// which may not have been recomputed yet right after a reload.
    func revealCard(at index: Int, animated: Bool) {
        guard let clipView = enclosingScrollView?.contentView else { return }
        let count = numberOfItems(inSection: 0)
        guard index >= 0, index < count else { return }

        let insets = PanelMetrics.rowInsets
        let stride = HistoryItemView.cardSize.width + PanelMetrics.cardSpacing
        let cardMinX = insets.left + CGFloat(index) * stride
        let cardMaxX = cardMinX + HistoryItemView.cardSize.width
        let contentWidth = insets.left + insets.right + CGFloat(count) * stride - PanelMetrics.cardSpacing

        let visible = clipView.bounds
        var x = visible.minX
        if cardMinX - insets.left < visible.minX {
            x = cardMinX - insets.left
        } else if cardMaxX + insets.right > visible.maxX {
            x = cardMaxX + insets.right - visible.width
        }
        x = max(0, min(x, contentWidth - visible.width))
        guard abs(x - visible.minX) > 0.5 else { return }

        let origin = NSPoint(x: x, y: visible.minY)
        if animated {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeOut)
                clipView.animator().setBoundsOrigin(origin)
            }
        } else {
            clipView.setBoundsOrigin(origin)
        }
        enclosingScrollView?.reflectScrolledClipView(clipView)
    }

    /// Index paths of the cards currently on screen, paired with their views.
    func visibleCards() -> [(index: Int, card: HistoryItemView)] {
        visibleItems().compactMap { item in
            guard let card = item as? HistoryItemView, let indexPath = indexPath(for: card) else { return nil }
            return (indexPath.item, card)
        }
    }
}
