import Foundation
import Testing
@testable import Swiftboard

@Test func textRoundTripsThroughWireFormat() throws {
    let original = ClipboardItem.text("hello, couch")
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)

    #expect(decoded.kind == .text)
    #expect(decoded.text == "hello, couch")
    // Hash is recomputed from content on decode, so both ends must agree.
    #expect(decoded.hash == original.hash)
}

@Test func imageRoundTripsThroughWireFormat() throws {
    let bytes = Data((0..<512).map { UInt8($0 % 256) })
    let original = ClipboardItem.image(png: bytes)
    let data = try JSONEncoder().encode(original)
    let decoded = try JSONDecoder().decode(ClipboardItem.self, from: data)

    #expect(decoded.kind == .image)
    #expect(decoded.imagePNG == bytes)
    #expect(decoded.hash == original.hash)
}

@Test func differentContentHashesDifferently() {
    #expect(ClipboardItem.text("a").hash != ClipboardItem.text("b").hash)
    // Same content is stable across separate constructions (cross-machine dedup).
    #expect(ClipboardItem.text("same").hash == ClipboardItem.text("same").hash)
}

@Test func argParserRequiresPeer() {
    #expect(throws: ArgError.self) {
        _ = try ArgParser.parse(["swiftboard"])
    }
}

@Test func argParserReadsOptions() throws {
    let config = try #require(
        try ArgParser.parse(["swiftboard", "--peer", "192.168.1.50", "--port", "9000", "--no-images"])
    )
    #expect(config.peerHost == "192.168.1.50")
    #expect(config.port == 9000)
    #expect(config.syncImages == false)
}
