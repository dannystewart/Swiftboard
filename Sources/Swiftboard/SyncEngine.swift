import Foundation
import Synchronization

/// Coordinates the local clipboard, the peer transport, and the dedup state.
///
/// Everything that touches the OS clipboard runs inside `state.withLock`, which does double duty:
/// it protects the dedup fields AND serializes clipboard access between the poll thread and the
/// receive thread (the Windows clipboard in particular is a single global object that dislikes
/// concurrent access).
final class SyncEngine: Sendable {
    private struct State {
        var lastToken: Int?
        var lastHash: String?
    }

    private let backend: any ClipboardBackend
    private let config: Config
    private let sendToPeer: @Sendable (ClipboardItem) -> Void
    private let state: Mutex<State>

    init(
        backend: any ClipboardBackend,
        config: Config,
        sendToPeer: @escaping @Sendable (ClipboardItem) -> Void,
    ) {
        self.backend = backend
        self.config = config
        self.sendToPeer = sendToPeer

        // Prime with the current clipboard so we don't broadcast whatever happened to be on the
        // clipboard before Swiftboard started.
        let token = backend.changeToken()
        let hash = backend.read(maxBytes: config.maxSizeBytes, syncImages: config.syncImages)?.hash
        self.state = Mutex(State(lastToken: token, lastHash: hash))
    }

    /// Called on each poll tick. Reads the clipboard only when the cheap change token moved, and
    /// only sends when the content hash is genuinely new.
    func pollLocal() {
        self.state.withLock { s in
            self.captureLocal(state: &s)
        }
    }

    /// Called on the receive thread when a frame arrives from the peer.
    func applyRemote(_ item: ClipboardItem) -> Bool {
        self.state.withLock { s in
            // Don't overwrite a local copy made since the last poll without first saving it.
            self.captureLocal(state: &s)
            if let existing = s.lastHash, existing == item.hash {
                Log.debug("Ignoring peer update; identical content already present.")
                return true
            }

            Log.info("Received \(item.summary) from peer; updating local clipboard.")
            guard self.backend.write(item) else {
                // A failed write can still clear/change the clipboard. Don't echo partial state.
                s.lastToken = self.backend.changeToken()
                s.lastHash = nil
                return false
            }

            // Re-read so our dedup state reflects how *this* platform now sees the clipboard.
            // Prevents the poll loop from echoing it back, even when re-encoding produces different
            // bytes than the sender had.
            let appliedToken = self.backend.changeToken()
            let settled = self.backend.read(
                maxBytes: self.config.maxSizeBytes,
                syncImages: self.config.syncImages,
            )
            s.lastToken = appliedToken
            s.lastHash = self.backend.changeToken() == appliedToken ? (settled?.hash ?? item.hash) : item.hash
            return true
        }
    }

    /// Must stay cheap after the snapshot: sendToPeer enqueues, never performs network I/O.
    private func captureLocal(state s: inout State) {
        let token = self.backend.changeToken()
        if let last = s.lastToken, last == token {
            return
        }

        guard
            let item = backend.read(
                maxBytes: config.maxSizeBytes,
                syncImages: config.syncImages,
            ) else
        {
            // A busy clipboard or a screenshot still being published should be retried on the next
            // tick, not marked as captured.
            return
        }
        s.lastToken = token
        if s.lastHash == item.hash {
            return
        }
        s.lastHash = item.hash
        self.sendToPeer(item)
    }
}
