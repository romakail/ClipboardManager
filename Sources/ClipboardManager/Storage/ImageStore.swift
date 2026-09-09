import AppKit
import Foundation

enum ImageStore {
    static let maxLongestSide: CGFloat = 2000

    static var imagesDirectory: URL {
        AppPaths.supportDirectory.appendingPathComponent("Images", isDirectory: true)
    }

    static func ensureDirectoryExists() {
        try? FileManager.default.createDirectory(at: imagesDirectory, withIntermediateDirectories: true)
    }

    /// Downscales (if needed) and saves the image as PNG, returning the filename and raw PNG data used for hashing.
    static func save(_ image: NSImage) -> (fileName: String, pngData: Data)? {
        ensureDirectoryExists()

        let resized = resizeIfNeeded(image)
        guard let tiff = resized.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let pngData = bitmap.representation(using: .png, properties: [:]) else {
            return nil
        }

        let fileName = "\(UUID().uuidString).png"
        let fileURL = imagesDirectory.appendingPathComponent(fileName)
        do {
            try pngData.write(to: fileURL, options: .atomic)
            return (fileName, pngData)
        } catch {
            return nil
        }
    }

    static func loadImage(fileName: String) -> NSImage? {
        let url = imagesDirectory.appendingPathComponent(fileName)
        return NSImage(contentsOf: url)
    }

    static func delete(fileName: String) {
        let url = imagesDirectory.appendingPathComponent(fileName)
        try? FileManager.default.removeItem(at: url)
    }

    private static func resizeIfNeeded(_ image: NSImage) -> NSImage {
        let size = image.size
        let longestSide = max(size.width, size.height)
        guard longestSide > maxLongestSide, longestSide > 0 else { return image }

        let scale = maxLongestSide / longestSide
        let newSize = NSSize(width: size.width * scale, height: size.height * scale)

        let newImage = NSImage(size: newSize)
        newImage.lockFocus()
        image.draw(in: NSRect(origin: .zero, size: newSize),
                   from: NSRect(origin: .zero, size: size),
                   operation: .copy,
                   fraction: 1.0)
        newImage.unlockFocus()
        return newImage
    }
}
