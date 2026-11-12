import AppKit

/// Resolves a source app's name, icon and a representative tint color extracted from the icon,
/// cached in memory since this is looked up repeatedly while scrolling and searching history.
enum AppIconResolver {
    struct Resolved {
        let name: String
        let icon: NSImage
        let tint: NSColor
    }

    /// Misses are cached too (as nil), so an uninstalled app isn't looked up again for every card.
    private static var cache: [String: Resolved?] = [:]

    static func resolve(bundleID: String?) -> Resolved? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }

        var resolved: Resolved?
        if let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            let icon = NSWorkspace.shared.icon(forFile: appURL.path)
            let name = FileManager.default.displayName(atPath: appURL.path).replacingOccurrences(of: ".app", with: "")
            resolved = Resolved(name: name, icon: icon, tint: vibrantColor(of: icon) ?? .systemGray)
        }
        cache[bundleID] = resolved
        return resolved
    }

    /// The icon's dominant *colorful* tone. A plain average turns most icons into a muddy grey, so
    /// pixels are weighted by how saturated they are, and the result is kept within a brightness
    /// range that works as a header background.
    private static func vibrantColor(of image: NSImage) -> NSColor? {
        let side = 24
        guard let context = CGContext(
            data: nil,
            width: side,
            height: side,
            bitsPerComponent: 8,
            bytesPerRow: side * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        var rect = CGRect(x: 0, y: 0, width: side, height: side)
        guard let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil) else { return nil }
        context.draw(cgImage, in: rect)
        guard let data = context.data else { return nil }
        let pixels = data.bindMemory(to: UInt8.self, capacity: side * side * 4)

        var red = 0.0, green = 0.0, blue = 0.0, totalWeight = 0.0
        for index in 0..<(side * side) {
            let offset = index * 4
            let alpha = Double(pixels[offset + 3]) / 255
            guard alpha > 0.5 else { continue }
            // Undo premultiplication.
            let r = min(1, Double(pixels[offset]) / 255 / alpha)
            let g = min(1, Double(pixels[offset + 1]) / 255 / alpha)
            let b = min(1, Double(pixels[offset + 2]) / 255 / alpha)
            let maxChannel = max(r, g, b)
            let saturation = maxChannel == 0 ? 0 : (maxChannel - min(r, g, b)) / maxChannel
            let weight = saturation * saturation + 0.02
            red += r * weight
            green += g * weight
            blue += b * weight
            totalWeight += weight
        }
        guard totalWeight > 0 else { return nil }

        let average = NSColor(srgbRed: red / totalWeight, green: green / totalWeight, blue: blue / totalWeight, alpha: 1)
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0, alpha: CGFloat = 0
        average.getHue(&hue, saturation: &saturation, brightness: &brightness, alpha: &alpha)
        return NSColor(
            hue: hue,
            saturation: min(saturation, 0.85),
            brightness: min(max(brightness, 0.38), 0.82),
            alpha: 1
        ).usingColorSpace(.sRGB)
    }
}
