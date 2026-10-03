import XCTest
@testable import FluxKit

final class ClipImageTests: XCTestCase {
    func testPacketMatchesTheAndroidApp() {
        // ClipImage.kt: Packet(FLUX_CLIPBOARD_IMAGE, bodyOf("mime" to mime), payloadSize, payloadPort)
        let p = ClipImage.packet(mime: "image/jpeg", size: 2048, port: 1742, id: 1_790_000_000_000)
        let line = String(decoding: p.serialize(), as: UTF8.self)
        XCTAssertTrue(line.hasSuffix("\n"))
        let expected = #"{"id":1790000000000,"type":"flux.clipboard.image","body":{"mime":"image/jpeg"},"payloadSize":2048,"payloadTransferInfo":{"port":1742}}"#
        XCTAssertEqual(json(line), json(expected))
    }

    func testReadsTheImageThatFluxdSends() {
        // clipboard.go sendClipImage: proto.New(TypeFluxClipboardImage, {"mime": mime}) with a payload.
        let tunnel = Packet.parse(#"{"id":1790000000002,"type":"flux.clipboard.image","body":{"mime":"image/webp"},"payloadSize":5,"payloadTransferInfo":{"tunnel":"t1"}}"#)!
        XCTAssertEqual(tunnel.type, PacketType.fluxClipboardImage)
        XCTAssertTrue(ClipImage.accepts(tunnel))
        XCTAssertEqual(tunnel.payloadTunnel, "t1")
        XCTAssertEqual(ClipImage.mime(of: tunnel), "image/webp")
    }

    func testUnknownTypeIsPNG() {
        // Android: p.string("mime")?.takeIf { it in TYPES } ?: "image/png"
        XCTAssertEqual(ClipImage.mime(of: packet(["mime": "image/tiff"], size: 5)), "image/png")
        XCTAssertEqual(ClipImage.mime(of: packet([:], size: 5)), "image/png")
    }

    func testSizeLimit() {
        XCTAssertEqual(ClipImage.maxBytes, 16 << 20, "fluxd and Android use 16 MiB")
        XCTAssertTrue(ClipImage.accepts(packet(["mime": "image/png"], size: 16 << 20)))
        XCTAssertFalse(ClipImage.accepts(packet(["mime": "image/png"], size: (16 << 20) + 1)))
        XCTAssertFalse(ClipImage.accepts(packet(["mime": "image/png"], size: -1)), "an unknown size is not an image")
        XCTAssertFalse(ClipImage.accepts(Packet(PacketType.fluxClipboardImage, ["mime": "image/png"])), "no payload")
    }

    func testTypes() {
        XCTAssertEqual(ClipImage.types, ["image/png", "image/jpeg", "image/gif", "image/webp"])
        XCTAssertEqual(ClipImage.pasteboardType("image/png"), "public.png")
        XCTAssertEqual(ClipImage.pasteboardType("image/jpeg"), "public.jpeg")
        XCTAssertEqual(ClipImage.pasteboardType("image/gif"), "com.compuserve.gif")
        XCTAssertEqual(ClipImage.pasteboardType("image/webp"), "org.webmproject.webp")
    }

    func testPickFromThePasteboardTypes() {
        XCTAssertEqual(ClipImage.pick(["public.png"]), .data(type: "public.png", mime: "image/png"))
        XCTAssertEqual(ClipImage.pick(["public.heic", "public.jpeg"]), .data(type: "public.jpeg", mime: "image/jpeg"),
                       "a type that the computer reads wins over one that it does not")
        XCTAssertEqual(ClipImage.pick(["public.heic"]), .convert, "another image goes as a PNG")
        XCTAssertNil(ClipImage.pick(["public.utf8-plain-text"]))
        XCTAssertNil(ClipImage.pick(["public.png", "public.utf8-plain-text"]), "text wins, like on Android")
        XCTAssertNil(ClipImage.pick([]))
    }

    func testReceivedRejection() {
        let p = Tunnel.failed(token: "t1", error: ClipImage.rejected)
        XCTAssertEqual(p.string("error"), "the phone does not accept this clipboard image")
    }

    func testCapabilities() {
        let plain = ClipboardPlugin.capabilities(images: false, sync: true)
        XCTAssertEqual(plain.incoming, [PacketType.clipboard, PacketType.clipboardConnect])
        XCTAssertEqual(plain.outgoing, [PacketType.clipboard, PacketType.clipboardConnect])
        XCTAssertEqual(ClipboardPlugin.capabilities(images: false, sync: false).incoming, plain.incoming, "the Mac does not change")

        let on = ClipboardPlugin.capabilities(images: true, sync: true)
        XCTAssertEqual(on.incoming, [PacketType.clipboard, PacketType.clipboardConnect, PacketType.fluxClipboardImage])
        XCTAssertEqual(on.outgoing, [PacketType.clipboard, PacketType.clipboardConnect, PacketType.fluxClipboardImage])
        let off = ClipboardPlugin.capabilities(images: true, sync: false)
        XCTAssertEqual(off.incoming, [PacketType.clipboard, PacketType.clipboardConnect], "images come only while sync is on, like on Android")
        XCTAssertEqual(off.outgoing, on.outgoing, "the Send Clipboard action still sends images")
    }

    @MainActor
    func testTheMacDoesNotSyncImages() throws {
        let clipboard = ClipboardPlugin()
        let core = try makeCore(plugins: [clipboard])
        XCTAssertFalse(core.incomingCapabilities.contains(PacketType.fluxClipboardImage))
        XCTAssertFalse(core.outgoingCapabilities.contains(PacketType.fluxClipboardImage))
        XCTAssertFalse(clipboard.handledTypes.contains(PacketType.fluxClipboardImage))
    }

    #if os(iOS)
    @MainActor
    func testTheIPhoneTakesImagesWhileSyncIsOn() throws {
        let clipboard = ClipboardPlugin(images: true)
        let core = try makeCore(plugins: [clipboard])
        XCTAssertTrue(core.incomingCapabilities.contains(PacketType.fluxClipboardImage))
        clipboard.setSync(false)
        XCTAssertFalse(core.incomingCapabilities.contains(PacketType.fluxClipboardImage))
        XCTAssertTrue(core.outgoingCapabilities.contains(PacketType.fluxClipboardImage))
        XCTAssertTrue(clipboard.handledTypes.contains(PacketType.fluxClipboardImage), "the route stays, so that sync can turn on later")
        clipboard.setSync(true)
        XCTAssertTrue(core.incomingCapabilities.contains(PacketType.fluxClipboardImage))
    }

    func testSyncLeavesMarkedSecretsAlone() {
        XCTAssertTrue(ClipboardText.isPrivate(["public.utf8-plain-text", "org.nspasteboard.ConcealedType"]))
        XCTAssertTrue(ClipboardText.isPrivate(["org.nspasteboard.TransientType"]))
        XCTAssertTrue(ClipboardText.isPrivate(["public.utf8-plain-text", "org.nspasteboard.AutoGeneratedType"]))
        XCTAssertFalse(ClipboardText.isPrivate(["public.utf8-plain-text"]))
        XCTAssertFalse(ClipboardText.isPrivate([]))
    }
    #endif

    private func makeCore(plugins: [FluxPlugin]) throws -> FluxCore {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let suite = "org.omarchy.flux.test." + UUID().uuidString
        var config = LanConfig()
        config.loopbackOnly = true
        let core = try FluxCore(paths: FluxPaths(data: dir, suite: suite), lanConfig: config, plugins: plugins)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: dir)
            UserDefaults().removePersistentDomain(forName: suite)
        }
        return core
    }

    private func packet(_ body: [String: Any?], size: Int64) -> Packet {
        Packet(PacketType.fluxClipboardImage, body, payloadSize: size, payloadPort: 12070)
    }

    private func json(_ s: String) -> NSDictionary? {
        (try? JSONSerialization.jsonObject(with: Data(s.utf8))) as? NSDictionary
    }
}
