#if os(Windows)
import Foundation
import WinSDK
import CSTBImage

// NOTE: This file only compiles on Windows and has NOT been build-verified on a
// Windows toolchain from the dev machine. The Win32/WinSDK API surface (BOOL ->
// WindowsBool, HANDLE, GlobalAlloc/GlobalLock) is the most likely place to need
// small adjustments on first Windows build.

// Standard clipboard format identifiers. Defined locally as UINT to avoid any
// dependence on how the CF_* macros are (or aren't) surfaced by the overlay.
private let cfUnicodeText: UINT = 13
private let cfDIB: UINT = 8
private let cfDIBV5: UINT = 17

private let gmemMoveable: UINT = 0x0002

struct WindowsClipboardBackend: ClipboardBackend {
    func changeToken() -> Int {
        Int(GetClipboardSequenceNumber())
    }

    func read(maxBytes: Int, syncImages: Bool) -> ClipboardItem? {
        guard openClipboardWithRetry() else {
            Log.debug("Clipboard was busy; skipping this read.")
            return nil
        }
        defer { CloseClipboard() }

        if syncImages, let png = readImagePNG() {
            guard png.count <= maxBytes else {
                Log.warn("Clipboard image too large (\(png.count) bytes); skipping.")
                return nil
            }
            return .image(png: png)
        }

        if let text = readUnicodeText(), !text.isEmpty {
            guard text.utf8.count <= maxBytes else {
                Log.warn("Clipboard text too large (\(text.utf8.count) bytes); skipping.")
                return nil
            }
            return .text(text)
        }

        return nil
    }

    func write(_ item: ClipboardItem) {
        guard openClipboardWithRetry() else {
            Log.warn("Could not open clipboard to write; dropping update.")
            return
        }
        defer { CloseClipboard() }

        guard EmptyClipboard() else {
            Log.warn("EmptyClipboard failed; dropping update.")
            return
        }

        switch item.kind {
        case .text:
            writeUnicodeText(item.text ?? "")
        case .image:
            if let png = item.imagePNG {
                writeImagePNG(png)
            }
        }
    }

    // MARK: - Open with retry

    private func openClipboardWithRetry() -> Bool {
        for attempt in 1...5 {
            if OpenClipboard(nil) {
                return true
            }
            if attempt < 5 {
                Thread.sleep(forTimeInterval: 0.03)
            }
        }
        return false
    }

    // MARK: - Text

    private func readUnicodeText() -> String? {
        guard IsClipboardFormatAvailable(cfUnicodeText) else { return nil }
        guard let handle = GetClipboardData(cfUnicodeText) else { return nil }
        guard let locked = GlobalLock(handle) else { return nil }
        defer { GlobalUnlock(handle) }
        let ptr = locked.assumingMemoryBound(to: UInt16.self)
        return String(decodingCString: ptr, as: UTF16.self)
    }

    private func writeUnicodeText(_ text: String) {
        var utf16 = Array(text.utf16)
        utf16.append(0) // null terminator
        let byteCount = utf16.count * MemoryLayout<UInt16>.size
        guard let handle = GlobalAlloc(gmemMoveable, SIZE_T(byteCount)) else { return }
        guard let dest = GlobalLock(handle) else {
            GlobalFree(handle)
            return
        }
        utf16.withUnsafeBytes { src in
            dest.copyMemory(from: src.baseAddress!, byteCount: byteCount)
        }
        GlobalUnlock(handle)
        // On success the system owns the handle; do not free it.
        if SetClipboardData(cfUnicodeText, handle) == nil {
            GlobalFree(handle)
        }
    }

    // MARK: - Image (read)

    private func readImagePNG() -> Data? {
        let format: UINT
        if IsClipboardFormatAvailable(cfDIBV5) {
            format = cfDIBV5
        } else if IsClipboardFormatAvailable(cfDIB) {
            format = cfDIB
        } else {
            return nil
        }

        guard let handle = GetClipboardData(format) else { return nil }
        let size = Int(GlobalSize(handle))
        guard size > 0, let locked = GlobalLock(handle) else { return nil }
        defer { GlobalUnlock(handle) }

        var dib = [UInt8](repeating: 0, count: size)
        dib.withUnsafeMutableBytes { buf in
            buf.baseAddress!.copyMemory(from: locked, byteCount: size)
        }

        guard let bmp = dibToBMP(dib) else { return nil }
        return decodeToPNG(bmp)
    }

    // Prepend a BITMAPFILEHEADER so stb can decode the DIB as a BMP.
    private func dibToBMP(_ dib: [UInt8]) -> [UInt8]? {
        guard dib.count >= 40 else { return nil }
        let headerSize = Int(readLE32(dib, 0))
        let effectiveHeader = (headerSize < 40 || headerSize > dib.count) ? 40 : headerSize
        let bpp = Int(readLE16(dib, 14))
        let clrUsed = Int(readLE32(dib, 32))
        let paletteEntries: Int
        if clrUsed != 0 {
            paletteEntries = clrUsed
        } else if bpp <= 8 {
            paletteEntries = 1 << bpp
        } else {
            paletteEntries = 0
        }
        let paletteBytes = paletteEntries * 4
        let offBits = 14 + effectiveHeader + paletteBytes
        let fileSize = 14 + dib.count

        var header = [UInt8]()
        header.append(0x42) // 'B'
        header.append(0x4D) // 'M'
        appendLE32(&header, UInt32(fileSize))
        appendLE16(&header, 0)
        appendLE16(&header, 0)
        appendLE32(&header, UInt32(offBits))
        return header + dib
    }

    private func decodeToPNG(_ encoded: [UInt8]) -> Data? {
        var width: Int32 = 0
        var height: Int32 = 0
        let rgba: UnsafeMutablePointer<UInt8>? = encoded.withUnsafeBufferPointer { buf in
            cstb_decode_to_rgba(buf.baseAddress, Int32(buf.count), &width, &height)
        }
        guard let rgba, width > 0, height > 0 else { return nil }
        defer { cstb_free(rgba) }

        var pngLen: Int32 = 0
        guard let png = cstb_encode_rgba_to_png(rgba, width, height, &pngLen), pngLen > 0 else {
            return nil
        }
        defer { cstb_free(png) }
        return Data(bytes: png, count: Int(pngLen))
    }

    // MARK: - Image (write)

    private func writeImagePNG(_ png: Data) {
        var width: Int32 = 0
        var height: Int32 = 0
        let rgba: UnsafeMutablePointer<UInt8>? = png.withUnsafeBytes { raw in
            cstb_decode_to_rgba(
                raw.bindMemory(to: UInt8.self).baseAddress,
                Int32(raw.count),
                &width,
                &height
            )
        }
        guard let rgba, width > 0, height > 0 else {
            Log.warn("Failed to decode incoming PNG for clipboard write.")
            return
        }
        defer { cstb_free(rgba) }

        let w = Int(width)
        let h = Int(height)
        let dib = buildBGRADIB(rgba: rgba, width: w, height: h)

        guard let handle = GlobalAlloc(gmemMoveable, SIZE_T(dib.count)) else { return }
        guard let dest = GlobalLock(handle) else {
            GlobalFree(handle)
            return
        }
        dib.withUnsafeBytes { src in
            dest.copyMemory(from: src.baseAddress!, byteCount: dib.count)
        }
        GlobalUnlock(handle)
        if SetClipboardData(cfDIB, handle) == nil {
            GlobalFree(handle)
        }
    }

    // Build a 32bpp BI_RGB DIB: BITMAPINFOHEADER + bottom-up BGRA rows.
    private func buildBGRADIB(rgba: UnsafeMutablePointer<UInt8>, width: Int, height: Int) -> [UInt8] {
        let rowBytes = width * 4
        let imageSize = rowBytes * height

        var dib = [UInt8]()
        dib.reserveCapacity(40 + imageSize)

        appendLE32(&dib, 40)                 // biSize
        appendLE32(&dib, UInt32(width))      // biWidth
        appendLE32(&dib, UInt32(height))     // biHeight (positive => bottom-up)
        appendLE16(&dib, 1)                  // biPlanes
        appendLE16(&dib, 32)                 // biBitCount
        appendLE32(&dib, 0)                  // biCompression = BI_RGB
        appendLE32(&dib, UInt32(imageSize))  // biSizeImage
        appendLE32(&dib, 0)                  // biXPelsPerMeter
        appendLE32(&dib, 0)                  // biYPelsPerMeter
        appendLE32(&dib, 0)                  // biClrUsed
        appendLE32(&dib, 0)                  // biClrImportant

        // Rows bottom-up, pixels RGBA -> BGRA.
        for row in stride(from: height - 1, through: 0, by: -1) {
            let srcRow = row * rowBytes
            for col in 0..<width {
                let i = srcRow + col * 4
                let r = rgba[i]
                let g = rgba[i + 1]
                let b = rgba[i + 2]
                let a = rgba[i + 3]
                dib.append(b)
                dib.append(g)
                dib.append(r)
                dib.append(a)
            }
        }
        return dib
    }

    // MARK: - Little-endian helpers

    private func readLE16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8)
    }

    private func readLE32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(bytes[offset])
            | (UInt32(bytes[offset + 1]) << 8)
            | (UInt32(bytes[offset + 2]) << 16)
            | (UInt32(bytes[offset + 3]) << 24)
    }

    private func appendLE16(_ bytes: inout [UInt8], _ value: UInt16) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
    }

    private func appendLE32(_ bytes: inout [UInt8], _ value: UInt32) {
        bytes.append(UInt8(value & 0xFF))
        bytes.append(UInt8((value >> 8) & 0xFF))
        bytes.append(UInt8((value >> 16) & 0xFF))
        bytes.append(UInt8((value >> 24) & 0xFF))
    }
}
#endif
