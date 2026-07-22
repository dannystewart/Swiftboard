#if os(macOS)
import AppKit
import Foundation

struct MacClipboardBackend: ClipboardBackend {
    func changeToken() -> Int {
        NSPasteboard.general.changeCount
    }

    func read(maxBytes: Int, syncImages: Bool) -> ClipboardItem? {
        let pb = NSPasteboard.general

        if syncImages, let png = readImagePNG(pb) {
            guard png.count <= maxBytes else {
                Log.warn("Clipboard image too large (\(png.count) bytes); skipping.")
                return nil
            }
            return .image(png: png)
        }

        if let text = pb.string(forType: .string), !text.isEmpty {
            guard text.utf8.count <= maxBytes else {
                Log.warn("Clipboard text too large (\(text.utf8.count) bytes); skipping.")
                return nil
            }
            return .text(text)
        }

        return nil
    }

    func write(_ item: ClipboardItem) {
        let pb = NSPasteboard.general
        switch item.kind {
        case .text:
            pb.clearContents()
            pb.setString(item.text ?? "", forType: .string)
        case .image:
            guard let png = item.imagePNG else { return }
            pb.clearContents()
            // Write PNG plus a TIFF fallback, since some apps only read TIFF.
            pb.setData(png, forType: .png)
            if let rep = NSBitmapImageRep(data: png),
               let tiff = rep.tiffRepresentation {
                pb.setData(tiff, forType: .tiff)
            }
        }
    }

    private func readImagePNG(_ pb: NSPasteboard) -> Data? {
        if let png = pb.data(forType: .png) {
            return png
        }
        // Convert whatever bitmap the pasteboard has (commonly TIFF) to PNG.
        if let tiff = pb.data(forType: .tiff),
           let rep = NSBitmapImageRep(data: tiff),
           let png = rep.representation(using: .png, properties: [:]) {
            return png
        }
        return nil
    }
}
#endif
