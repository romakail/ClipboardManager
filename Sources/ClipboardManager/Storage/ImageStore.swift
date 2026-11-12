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

    // MARK: - Thumbnails

    final class Thumbnail {
        let image: NSImage
        /// Size of the full stored image, in pixels.
        let pixelSize: NSSize

        init(image: NSImage, pixelSize: NSSize) {
            self.image = image
            self.pixelSize = pixelSize
        }
    }

    private static let thumbnailCache: NSCache<NSString, Thumbnail> = {
        let cache = NSCache<NSString, Thumbnail>()
        cache.countLimit = 300
        return cache
    }()

    /// A small, cached rendition for history cards. Decoding the full stored image (up to 2000px)
    /// for every card each time the row redraws is what made scrolling through images stutter;
    /// stored files never change, so the file name is a safe cache key.
    static func thumbnail(fileName: String, maxPixelSize: Int = 440) -> Thumbnail? {
        if let cached = thumbnailCache.object(forKey: fileName as NSString) { return cached }

        let url = imagesDirectory.appendingPathComponent(fileName)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let pixelSize = NSSize(
            width: properties?[kCGImagePropertyPixelWidth] as? CGFloat ?? CGFloat(cgImage.width),
            height: properties?[kCGImagePropertyPixelHeight] as? CGFloat ?? CGFloat(cgImage.height)
        )
        // Sized at half its pixels so it stays crisp on Retina displays.
        let image = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width / 2, height: cgImage.height / 2))
        let thumbnail = Thumbnail(image: image, pixelSize: pixelSize)
        thumbnailCache.setObject(thumbnail, forKey: fileName as NSString)
        return thumbnail
    }

    /// Copies an existing image file under a fresh name, so the copy's lifecycle (e.g. saved-row
    /// items) is independent of whatever later deletes the original (e.g. history eviction).
    static func duplicate(fileName: String) -> String? {
        let sourceURL = imagesDirectory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: sourceURL) else { return nil }

        let newFileName = "\(UUID().uuidString).png"
        let destinationURL = imagesDirectory.appendingPathComponent(newFileName)
        do {
            try data.write(to: destinationURL, options: .atomic)
            return newFileName
        } catch {
            return nil
        }
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
