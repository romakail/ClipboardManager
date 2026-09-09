import AppKit

/// Resolves a source app's icon and a representative tint color extracted from it, cached in memory
/// since this is looked up repeatedly while scrolling through history cards.
enum AppIconResolver {
    struct Resolved {
        let icon: NSImage
        let tint: NSColor
    }

    static let defaultTint = NSColor.secondaryLabelColor

    private static var cache: [String: Resolved] = [:]

    static func resolve(bundleID: String?) -> Resolved? {
        guard let bundleID else { return nil }
        if let cached = cache[bundleID] { return cached }

        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
        let tint = averageColor(of: icon) ?? defaultTint
        let resolved = Resolved(icon: icon, tint: tint)
        cache[bundleID] = resolved
        return resolved
    }

    /// Cheap "dominant color" approximation: downsample the whole image to a single pixel.
    private static func averageColor(of image: NSImage) -> NSColor? {
        guard let tiff = image.tiffRepresentation, let bitmap = NSBitmapImageRep(data: tiff), let cgImage = bitmap.cgImage else {
            return nil
        }

        guard let context = CGContext(
            data: nil,
            width: 1,
            height: 1,
            bitsPerComponent: 8,
            bytesPerRow: 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let data = context.data else { return nil }

        let pixel = data.bindMemory(to: UInt8.self, capacity: 4)
        let alpha = CGFloat(pixel[3]) / 255.0
        guard alpha > 0.05 else { return nil }

        // Undo premultiplication.
        let r = min(1, CGFloat(pixel[0]) / 255.0 / alpha)
        let g = min(1, CGFloat(pixel[1]) / 255.0 / alpha)
        let b = min(1, CGFloat(pixel[2]) / 255.0 / alpha)
        return NSColor(srgbRed: r, green: g, blue: b, alpha: 1.0)
    }
}
