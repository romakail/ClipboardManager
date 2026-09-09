import Foundation

enum URLDetector {
    private static let detector = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.link.rawValue)

    /// Returns true if the entire trimmed string is a single detected link (not just text that contains one).
    static func isWholeStringURL(_ string: String) -> Bool {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let detector else { return false }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        let matches = detector.matches(in: trimmed, options: [], range: range)
        guard matches.count == 1, let match = matches.first else { return false }
        return match.range.length == range.length && match.url != nil
    }
}
