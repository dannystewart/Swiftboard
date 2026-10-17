import Dispatch
import Foundation
import Synchronization

// MARK: - TransferQueue

/// Owns immutable clipboard snapshots. Only the delivery worker performs network I/O; capture never
/// waits for a transfer, and a failed head item stays ahead of every later copy.
final class TransferQueue: Sendable {
    struct Entry: Sendable {
        let id: UUID = .init()
        let item: ClipboardItem

        var payload: Data? {
            guard let body = ClipboardWireFormat.encode(self.item) else { return nil }
            var data = Data([1]) // Acknowledged-transfer envelope, followed by a fixed-width UUID.
            data.append(contentsOf: self.id.uuidString.utf8)
            data.append(body)
            return data
        }
    }

    private let entries: Mutex<[Entry]> = .init([])
    private let delivery: Mutex<Void> = .init(())
    private let wake: DispatchSemaphore = .init(value: 0)

    func enqueue(_ item: ClipboardItem) {
        let count = self.entries.withLock { entries in
            entries.append(Entry(item: item))
            return entries.count
        }
        if count == 1 { self.wake.signal() }
        Log.info("Queued \(item.summary); \(count) update(s) pending.")
    }

    /// Sleep only when idle. A new capture wakes the worker immediately, without making capture
    /// wait for networking or imposing a retry-length delay on every ordinary copy.
    func waitForWork() {
        while self.entries.withLock({ $0.isEmpty }) {
            self.wake.wait()
        }
    }

    /// Synchronous and single-consumer, including when invoked concurrently. A true result means
    /// the peer acknowledged the head item, not merely that TCP accepted its bytes.
    @discardableResult
    func deliverNext(using send: (Entry) -> Bool) -> Bool {
        self.delivery.withLock { _ in
            guard let entry = self.entries.withLock({ $0.first }) else { return false }
            guard send(entry) else { return false }
            _ = self.entries.withLock { $0.removeFirst() }
            return true
        }
    }
}

// MARK: - TransferReceiver

/// Accessed only by the serial receive worker. Remember transfer identities rather than content: a
/// retry must not replay an old clipboard over a newer local copy.
struct TransferReceiver {
    private var lastDeliveredID: UUID?

    mutating func receive(
        _ payload: Data,
        maxBytes: Int,
        apply: (ClipboardItem) -> Bool,
    ) -> Bool {
        let id: UUID?
        let body: Data
        if payload.first == 1 {
            guard
                payload.count > 37,
                let value = String(data: payload.subdata(in: 1 ..< 37), encoding: .utf8),
                let parsed = UUID(uuidString: value) else { return false }
            id = parsed
            body = payload.subdata(in: 37 ..< payload.count)
            if self.lastDeliveredID == parsed { return true }
        } else {
            // Still accept old peers, though only updated senders can guarantee ordered retries.
            id = nil
            body = payload
        }
        guard
            let item = ClipboardWireFormat.decode(body, maxImageBytes: maxBytes),
            item.byteCount <= maxBytes,
            apply(item) else { return false }
        if let id { self.lastDeliveredID = id }
        return true
    }
}
