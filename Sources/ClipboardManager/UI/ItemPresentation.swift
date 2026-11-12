import AppKit

/// What a history item is shown as. Finer-grained than the stored `ClipboardItemType`: a color is
/// stored as plain text and only recognised at display time.
enum ItemKind {
    case text
    case link
    case image
    case color
}

/// The type filter chips above the history row.
enum HistoryFilter: Int, CaseIterable {
    case all
    case text
    case links
    case images
    case colors

    var title: String {
        switch self {
        case .all: return "All"
        case .text: return "Text"
        case .links: return "Links"
        case .images: return "Images"
        case .colors: return "Colors"
        }
    }

    func matches(_ item: ClipboardItem) -> Bool {
        switch self {
        case .all: return true
        case .text: return item.kind == .text
        case .links: return item.kind == .link
        case .images: return item.kind == .image
        case .colors: return item.kind == .color
        }
    }
}

extension ClipboardItem {
    private static let maxPreviewCharacters = 600

    private static let countFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private static let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .none
        return formatter
    }()

    var parsedColor: NSColor? {
        guard type == .text, let textContent, textContent.utf8.count <= 12 else { return nil }
        return NSColor.fromHexString(textContent)
    }

    var kind: ItemKind {
        switch type {
        case .image: return .image
        case .url: return .link
        case .text: return parsedColor == nil ? .text : .color
        }
    }

    var displayTitle: String {
        kind == .color ? "Color" : typeLabelText
    }

    /// The card body: real line breaks are kept (unlike `previewText`) and very long clips are cut
    /// short, since only the first few lines are ever visible.
    var bodyPreview: String {
        let text = textContent ?? ""
        return String(text.prefix(Self.maxPreviewCharacters)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var linkHost: String? {
        guard let host = detectedURL?.host else { return nil }
        return host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
    }

    /// The small caption at the bottom of a card. Images supply their own (pixel size).
    var metaText: String {
        switch kind {
        case .text:
            let count = textContent?.count ?? 0
            let formatted = Self.countFormatter.string(from: NSNumber(value: count)) ?? "\(count)"
            return count == 1 ? "1 character" : "\(formatted) characters"
        case .link:
            return linkHost ?? "Link"
        case .color:
            return (textContent ?? "").trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        case .image:
            return "Image"
        }
    }

    var relativeTimeText: String {
        let seconds = Date().timeIntervalSince(timestamp)
        switch seconds {
        case ..<60: return "Just now"
        case ..<3600: return "\(Int(seconds / 60)) min ago"
        case ..<86_400: return "\(Int(seconds / 3600)) h ago"
        case ..<(86_400 * 7): return "\(Int(seconds / 86_400)) d ago"
        default: return Self.dateFormatter.string(from: timestamp)
        }
    }

    /// Every search word has to appear somewhere in the item's text, its type, or its source app's
    /// name — so "safari link docs" finds a docs link copied from Safari.
    func matches(searchTokens: [String]) -> Bool {
        guard !searchTokens.isEmpty else { return true }
        let appName = AppIconResolver.resolve(bundleID: sourceAppBundleID)?.name ?? ""
        let fields = [textContent ?? "", displayTitle, appName]
        return searchTokens.allSatisfy { token in
            fields.contains { $0.localizedCaseInsensitiveContains(token) }
        }
    }
}
