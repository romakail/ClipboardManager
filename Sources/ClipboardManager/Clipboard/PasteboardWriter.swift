import AppKit
import Foundation

enum PasteboardWriter {
    static func write(_ item: ClipboardItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text, .url:
            guard let text = item.textContent else { return }
            pasteboard.setString(text, forType: .string)
        case .image:
            guard let fileName = item.imageFileName, let image = ImageStore.loadImage(fileName: fileName) else { return }
            guard let tiff = image.tiffRepresentation,
                  let bitmap = NSBitmapImageRep(data: tiff),
                  let pngData = bitmap.representation(using: .png, properties: [:]) else { return }
            pasteboard.setData(pngData, forType: .png)
        }
    }
}
