import Foundation

// MARK: - ClipboardBackend

/// The OS clipboard, abstracted so the sync logic never sees platform details.
/// Implementations must be safe to call from a single serialized context (the
/// SyncEngine guarantees that; see SyncEngine for why).
protocol ClipboardBackend: Sendable {
    // A cheap monotonic-ish token that changes whenever the clipboard changes,
    // so we can avoid opening/reading the clipboard on every poll.
    // macOS: NSPasteboard.changeCount. Windows: GetClipboardSequenceNumber.
    func changeToken() -> Int

    /// Read the current clipboard. Prefers an image when syncImages is true and
    /// an image is present, otherwise falls back to text. Returns nil when empty
    /// or when the payload exceeds maxBytes.
    func read(maxBytes: Int, syncImages: Bool) -> ClipboardItem?

    /// Replace the clipboard contents with the given item.
    func write(_ item: ClipboardItem)
}

// MARK: - ClipboardBackendFactory

enum ClipboardBackendFactory {
    static func make() -> any ClipboardBackend {
        #if os(macOS)
            return MacClipboardBackend()
        #elseif os(Windows)
            return WindowsClipboardBackend()
        #else
            fatalError("Swiftboard supports macOS and Windows only.")
        #endif
    }
}
