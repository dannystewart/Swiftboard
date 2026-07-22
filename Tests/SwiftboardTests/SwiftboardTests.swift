import Foundation
@testable import Swiftboard
import Testing

@Test func `text round trips through wire format`() throws {
    let original = ClipboardItem.text("hello, couch")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)

    #expect(decoded.kind == .text)
    #expect(decoded.text == "hello, couch")
    // Hash is recomputed from content on decode, so both ends must agree.
    #expect(decoded.hash == original.hash)
}

@Test func `image round trips through wire format`() throws {
    let bytes = Data((0 ..< 512).map { UInt8($0 % 256) })
    let original = ClipboardItem.image(png: bytes)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)

    #expect(decoded.kind == .image)
    #expect(decoded.imagePNG == bytes)
    #expect(decoded.hash == original.hash)
}

@Test func `different content hashes differently`() {
    #expect(ClipboardItem.text("a").hash != ClipboardItem.text("b").hash)
    // Same content is stable across separate constructions (cross-machine dedup).
    #expect(ClipboardItem.text("same").hash == ClipboardItem.text("same").hash)
}

@Test func `arg parser allows no peer for discovery`() throws {
    let config = try #require(try ArgParser.parse(["swiftboard"]))
    #expect(config.peerHost == nil)
    #expect(config.port == 8765)
}

@Test func `arg parser reads positional peer and port`() throws {
    let config = try #require(
        try ArgParser.parse(["swiftboard", "192.168.1.50", "--port", "9000", "--verbose"]),
    )
    #expect(config.peerHost == "192.168.1.50")
    #expect(config.port == 9000)
    #expect(config.verbose == true)
}

@Test func `arg parser rejects extra positional`() {
    #expect(throws: ArgError.self) {
        _ = try ArgParser.parse(["swiftboard", "192.168.1.50", "192.168.1.51"])
    }
}
