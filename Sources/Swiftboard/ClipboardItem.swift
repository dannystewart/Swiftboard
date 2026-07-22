import Foundation

// MARK: - ClipboardItem

/// A single clipboard payload moving between the two machines. Either UTF-8 text
/// or a PNG image. PNG is the common wire format; each platform converts to/from
/// its own native clipboard representation at the edges.
struct ClipboardItem: Sendable {
    enum Kind: String, Sendable {
        case text
        case image
    }

    let kind: Kind
    let text: String?
    let imagePNG: Data?

    /// Hash of the canonical content as *this* process sees it. It is recomputed
    /// from content on both ends (never trusted from the wire) so that identical
    /// text hashes identically on both machines.
    let hash: String

    var byteCount: Int {
        switch self.kind {
        case .text: self.text?.utf8.count ?? 0
        case .image: self.imagePNG?.count ?? 0
        }
    }

    var summary: String {
        switch self.kind {
        case .text: "text (\(self.byteCount) bytes)"
        case .image: "image (\(self.byteCount) bytes)"
        }
    }

    static func text(_ value: String) -> ClipboardItem {
        let bytes = Array(value.utf8)
        return ClipboardItem(
            kind: .text,
            text: value,
            imagePNG: nil,
            hash: contentHash([UInt8]("text:".utf8) + bytes),
        )
    }

    static func image(png: Data) -> ClipboardItem {
        ClipboardItem(
            kind: .image,
            text: nil,
            imagePNG: png,
            hash: contentHash([UInt8]("image:".utf8) + png),
        )
    }
}

// MARK: Codable

// JSON wire format. Images are base64-encoded. The hash is intentionally not
// encoded: the receiver recomputes it from content so both ends agree.
extension ClipboardItem: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind
        case text
        case imagePNGBase64 = "image_png_b64"
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(Kind.self, forKey: .kind)
        switch kind {
        case .text:
            let value = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            self = .text(value)

        case .image:
            let b64 = try container.decodeIfPresent(String.self, forKey: .imagePNGBase64) ?? ""
            guard let data = Data(base64Encoded: b64) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .imagePNGBase64,
                    in: container,
                    debugDescription: "image_png_b64 is not valid base64",
                )
            }
            self = .image(png: data)
        }
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(self.kind, forKey: .kind)
        switch self.kind {
        case .text:
            try container.encode(self.text ?? "", forKey: .text)
        case .image:
            try container.encode((self.imagePNG ?? Data()).base64EncodedString(), forKey: .imagePNGBase64)
        }
    }
}

extension ClipboardItem.Kind: Codable {}
