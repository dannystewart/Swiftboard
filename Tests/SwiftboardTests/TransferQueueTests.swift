import Foundation
@testable import Swiftboard
import Synchronization
import Testing

/// Failure story: copies captured while a large screenshot is in flight must remain immutable
/// snapshots and reach the receiver in capture order, rather than being replaced or overtaken.
@Test func `copies captured during a transfer are delivered in FIFO order`() {
    let clipboard = QueueTestClipboard()
    let queue = TransferQueue()
    let engine = SyncEngine(backend: clipboard, config: Config()) { queue.enqueue($0) }
    let images = (1 ... 3).map { ClipboardItem.image(png: Data(repeating: UInt8($0), count: 1024 * 1024)) }
    clipboard.copy(images[0])
    engine.pollLocal()

    var received = [String]()
    #expect(queue.deliverNext { entry in
        // More local copies happen before the first transfer returns its acknowledgement.
        for image in images.dropFirst() {
            clipboard.copy(image)
            engine.pollLocal()
        }
        received.append(entry.item.hash)
        return true
    })
    for _ in 0 ..< 2 {
        #expect(queue.deliverNext { entry in
            received.append(entry.item.hash)
            return true
        })
    }
    #expect(received == images.map(\.hash))
    #expect(!queue.deliverNext { _ in Issue.record("Delivered an already acknowledged item"); return true })
}

/// Failure story: a busy receiving clipboard must leave the same transfer at the head, not
/// acknowledge/drop it or let a newer copy overtake it.
@Test func `failed clipboard delivery retries the same head before later copies`() {
    let queue = TransferQueue()
    let clipboard = QueueTestClipboard()
    let engine = SyncEngine(backend: clipboard, config: Config()) { _ in }
    var receiver = TransferReceiver()
    queue.enqueue(.text("first"))
    queue.enqueue(.text("second"))
    clipboard.failWrites(true)

    var attemptedIDs = [UUID]()
    let failed = queue.deliverNext { entry in
        attemptedIDs.append(entry.id)
        return receiver.receive(entry.payload!, maxBytes: Config().maxSizeBytes, apply: engine.applyRemote)
    }
    #expect(!failed)
    clipboard.failWrites(false)
    for _ in 0 ..< 2 {
        #expect(queue.deliverNext { entry in
            attemptedIDs.append(entry.id)
            return receiver.receive(entry.payload!, maxBytes: Config().maxSizeBytes, apply: engine.applyRemote)
        })
    }
    #expect(attemptedIDs.count == 3)
    #expect(attemptedIDs[0] == attemptedIDs[1])
    #expect(attemptedIDs[1] != attemptedIDs[2])
    #expect(clipboard.writtenTexts == ["first", "second"])
}

/// Failure story: if the receiver applies a transfer but its acknowledgement is lost, retrying
/// must not replay that item over a subsequent local copy or create another history entry.
@Test func `lost acknowledgement does not replay over a newer local copy`() {
    let queue = TransferQueue()
    let clipboard = QueueTestClipboard()
    let engine = SyncEngine(backend: clipboard, config: Config()) { _ in }
    var receiver = TransferReceiver()
    queue.enqueue(.text("from peer"))
    let acknowledged = queue.deliverNext { entry in
        let applied = receiver.receive(entry.payload!, maxBytes: Config().maxSizeBytes, apply: engine.applyRemote)
        #expect(applied)
        return false // Application succeeded, but the acknowledgement never reached the sender.
    }
    #expect(!acknowledged)
    clipboard.copy(.text("new local copy"))
    #expect(queue.deliverNext { entry in
        receiver.receive(entry.payload!, maxBytes: Config().maxSizeBytes, apply: engine.applyRemote)
    })
    #expect(clipboard.read(maxBytes: Config().maxSizeBytes, syncImages: true)?.text == "new local copy")
    #expect(clipboard.writtenTexts == ["from peer"])
}

// MARK: - QueueTestClipboard

private final class QueueTestClipboard: ClipboardBackend, Sendable {
    private struct State {
        var token = 0
        var item: ClipboardItem?
        var failWrites = false
        var writtenTexts: [String] = []
    }

    private let state: Mutex = .init(State())

    var writtenTexts: [String] { self.state.withLock { $0.writtenTexts } }

    func copy(_ item: ClipboardItem) {
        self.state.withLock { state in
            state.item = item
            state.token += 1
        }
    }

    func failWrites(_ value: Bool) { self.state.withLock { $0.failWrites = value } }
    func changeToken() -> Int { self.state.withLock { $0.token } }
    func read(maxBytes _: Int, syncImages _: Bool) -> ClipboardItem? { self.state.withLock { $0.item } }

    func write(_ item: ClipboardItem) -> Bool {
        self.state.withLock { state in
            guard !state.failWrites else { return false }
            state.item = item
            state.token += 1
            if let text = item.text { state.writtenTexts.append(text) }
            return true
        }
    }
}
