import AppKit
import Foundation

enum PasteboardWriter {
    /// `plainTextOnly` drops any captured RTF/HTML so the receiving app gets unformatted text.
    static func write(_ item: ClipboardItem, plainTextOnly: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()

        switch item.type {
        case .text, .url:
            guard let text = item.textContent else { return }
            if !plainTextOnly {
                if let rtf = item.rtfData { pasteboard.setData(rtf, forType: .rtf) }
                if let html = item.htmlData { pasteboard.setData(html, forType: .html) }
            }
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
