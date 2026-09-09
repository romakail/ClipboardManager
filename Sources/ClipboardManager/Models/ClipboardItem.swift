import Foundation

enum ClipboardItemType: String, Codable {
    case text
    case url
    case image
}

struct ClipboardItem: Codable, Identifiable, Equatable {
    private static let screenshotBundleID = "com.apple.screencaptureui"

    let id: UUID
    let type: ClipboardItemType
    var timestamp: Date
    var textContent: String?
    var imageFileName: String?
    var contentHash: String
    /// Bundle identifier of whatever app was frontmost at capture time, if known.
    var sourceAppBundleID: String?

    var previewText: String {
        switch type {
        case .text, .url:
            let collapsed = (textContent ?? "").replacingOccurrences(of: "\n", with: " ")
            return collapsed
        case .image:
            return "Image"
        }
    }

    var detectedURL: URL? {
        guard type == .url, let textContent else { return nil }
        return URL(string: textContent)
    }

    var isScreenshot: Bool {
        type == .image && sourceAppBundleID == Self.screenshotBundleID
    }

    var typeLabelText: String {
        switch type {
        case .text: return "Text"
        case .url: return "Link"
        case .image: return isScreenshot ? "Screenshot" : "Image"
        }
    }
}
