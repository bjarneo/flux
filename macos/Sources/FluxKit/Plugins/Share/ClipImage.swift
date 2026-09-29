import Foundation
#if os(iOS)
import Crypto
import UIKit
#endif
import UniformTypeIdentifiers

/// Images on the clipboard: flux.clipboard.image, like in Flux for Android.
/// The payload is a PNG, JPEG, GIF, or WebP image, and the body names its
/// MIME type: {"mime": "image/png"}. Only the iOS app syncs images. The Mac
/// app neither advertises nor handles the type.
public enum ClipImage {
    /// The largest image that Flux syncs. fluxd and Android use the same limit.
    public static let maxBytes: Int64 = 16 << 20

    /// The image types that Flux syncs.
    public static let types = ["image/png", "image/jpeg", "image/gif", "image/webp"]

    /// The tunnel error for an image that this device does not take.
    static let rejected = "the phone does not accept this clipboard image"

    /// The packet that offers an image on a payload port.
    public static func packet(mime: String, size: Int64, port: Int, id: Int64 = Packet.now()) -> Packet {
        Packet(PacketType.fluxClipboardImage, ["mime": mime], id: id, payloadSize: size, payloadPort: port)
    }

    /// Reports whether the packet carries an image that Flux takes: a
    /// payload of 1 byte up to `maxBytes`.
    static func accepts(_ p: Packet) -> Bool {
        p.hasPayload && p.payloadSize > 0 && p.payloadSize <= maxBytes
    }

    /// The type of the image in the packet. An unknown type is PNG, like on Android.
    static func mime(of p: Packet) -> String {
        p.string("mime").flatMap { types.contains($0) ? $0 : nil } ?? "image/png"
    }

    /// The pasteboard type of an image type.
    static func pasteboardType(_ mime: String) -> String {
        UTType(mimeType: mime, conformingTo: .image)?.identifier ?? UTType.png.identifier
    }

    /// What goes out for the types of the first pasteboard item.
    enum Pick: Equatable {
        /// The data of the pasteboard type goes out as is.
        case data(type: String, mime: String)
        /// An image in another format goes out as a PNG.
        case convert
    }

    /// Picks the image to send from the types of the first pasteboard item.
    /// Text wins over an image, like on Android, where an item with text is
    /// text. A type that the computer reads wins over one that it does not.
    static func pick(_ pasteboardTypes: [String]) -> Pick? {
        let list = pasteboardTypes.compactMap { UTType($0) }
        if list.contains(where: { $0.conforms(to: .text) }) { return nil }
        for type in list {
            if let mime = type.preferredMIMEType, types.contains(mime) { return .data(type: type.identifier, mime: mime) }
        }
        return list.contains { $0.conforms(to: .image) } ? .convert : nil
    }
}

#if os(iOS)

/// The image of the general pasteboard.
enum ClipboardImage {
    /// An image that the pasteboard holds.
    struct Image {
        let data: Data
        let mime: String
    }

    /// Reports whether the pasteboard holds an image, without reading it,
    /// so without the paste prompt of iOS.
    @MainActor
    static var available: Bool {
        let pb = UIPasteboard.general
        return pb.hasImages && ClipImage.pick(pb.types) != nil
    }

    /// Reads the image on the pasteboard, or nil when it holds text or no image.
    @MainActor
    static func read() -> Image? {
        let pb = UIPasteboard.general
        guard pb.hasImages, let pick = ClipImage.pick(pb.types) else { return nil }
        switch pick {
        case .data(let type, let mime):
            return pb.data(forPasteboardType: type).map { Image(data: $0, mime: mime) }
        case .convert:
            return pb.image?.pngData().map { Image(data: $0, mime: "image/png") }
        }
    }

    /// Puts an image on the pasteboard in its own format.
    @MainActor
    static func write(_ data: Data, mime: String) {
        UIPasteboard.general.setData(data, forPasteboardType: ClipImage.pasteboardType(mime))
    }

    /// Identifies an image, so that an image from a computer does not go back.
    static func digest(_ data: Data) -> Data { Data(SHA256.hash(data: data)) }
}

/// Moves clipboard images between this device and a computer.
enum ClipImageTransfer {
    /// Receives the image of the packet through the tunnel `token`.
    static func receive(_ p: Packet, token: String, tls: FluxTLS, cert: [UInt8], announce: @escaping @Sendable (Packet) -> Void) async throws -> Data {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("flux-clip-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("image")
        guard FileManager.default.createFile(atPath: file.path, contents: nil) else { throw FluxError("cannot create \(file.path)") }
        let handle = try FileHandle(forWritingTo: file)
        do {
            let stream = try await Tunnel.accept(tls: tls, expected: cert, token: token, announce: announce)
            try await stream.receive(into: handle, size: p.payloadSize)
            try handle.close()
        } catch {
            try? handle.close()
            throw error
        }
        let data = try Data(contentsOf: file)
        guard Int64(data.count) == p.payloadSize else { throw FluxError("received \(data.count) of \(p.payloadSize) bytes") }
        return data
    }

    /// Offers the image to 1 computer on a payload port and streams it
    /// when the computer connects with its paired certificate.
    static func send(_ file: URL, size: Int64, mime: String, to deviceId: String, cert: [UInt8], core: FluxCore) async throws {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        let server = try await PayloadServer.open(tls: core.tls, expected: cert)
        guard core.send(ClipImage.packet(mime: mime, size: size, port: server.port), to: deviceId) else {
            server.close()
            throw FluxError("Not connected")
        }
        let stream = try await server.accept()
        try await stream.send(from: handle, size: size)
    }
}

#endif
