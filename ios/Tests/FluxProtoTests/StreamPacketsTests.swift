import XCTest
@testable import FluxProto

/// M5 packet vectors: `flux.webcam`/`flux.mic`/`flux.screen` builders +
/// desktop replies. Field shapes mirror `internal/core/{webcam,mic,
/// screen}.go`, Android `webcam/WebcamProtocol.kt`,
/// `mic/MicProtocol.kt`, `screen/ScreenProtocol.kt` — asserted through
/// serialize/parse round-trips. Golden NAL vectors live in
/// `FluxCameraTests` (`AnnexBTests`); PCM vectors in `FluxStreamTests`.
final class StreamPacketsTests: XCTestCase {
    // MARK: - Capabilities

    func testStreamCapsAreInBothLists() {
        for cap in [PacketType.fluxWebcam, PacketType.fluxMic, PacketType.fluxScreen] {
            XCTAssertTrue(incomingCapabilities.contains(cap), cap)
            XCTAssertTrue(outgoingCapabilities.contains(cap), cap)
        }
    }

    func testStreamKinds() {
        XCTAssertEqual(PacketType.fluxWebcam, StreamKind.webcam.packetType)
        XCTAssertEqual(PacketType.fluxMic, StreamKind.mic.packetType)
        XCTAssertEqual(PacketType.fluxScreen, StreamKind.screen.packetType)
        XCTAssertEqual(PacketType.fluxWebcam, StreamKind.webcam.stopPacket().type)
        XCTAssertEqual(PacketType.fluxMic, StreamKind.mic.stopPacket().type)
        XCTAssertEqual(PacketType.fluxScreen, StreamKind.screen.stopPacket().type)
    }

    // MARK: - Webcam start/stop

    func testWebcamStartBodyHasEveryField() throws {
        let p = WebcamPackets.start(port: 1742, width: 1920, height: 1080)
        XCTAssertEqual(PacketType.fluxWebcam, p.type)
        XCTAssertEqual("start", p.string("state"))
        XCTAssertEqual(1742, p.int("port"))
        XCTAssertEqual(1920, p.int("width"))
        XCTAssertEqual(1080, p.int("height"))
        XCTAssertEqual(30, p.int("fps"))
        XCTAssertEqual("h264", p.string("codec"))
        let back = try XCTUnwrap(Packet.parse(try p.serialize()))
        XCTAssertEqual(1742, back.int("port"))
        XCTAssertEqual(1920, back.int("width"))
        XCTAssertEqual("h264", back.string("codec"))
    }

    func testWebcamStopAndError() throws {
        XCTAssertEqual("stop", WebcamPackets.stop().string("state"))
        let err = try XCTUnwrap(Packet.parse(try WebcamPackets.error("no camera").serialize()))
        XCTAssertEqual("error", err.string("state"))
        XCTAssertEqual("no camera", err.string("message"))
    }

    func testWebcamConfigCarriesSettingsAndCaps() throws {
        let p = WebcamPackets.config(
            config: ["aspect": .string("16:9"), "mirror": .bool(false)],
            caps: ["zoomMax": .double(8)])
        let back = try XCTUnwrap(Packet.parse(try p.serialize()))
        XCTAssertEqual("config", back.string("state"))
        XCTAssertEqual("16:9", back.obj("config")?["aspect"]?.string)
        XCTAssertEqual(8, back.obj("caps")?["zoomMax"]?.double)
    }

    // MARK: - Webcam replies

    func testWebcamParsesReplies() {
        let live = WebcamReply.parse(Packet.of(
            PacketType.fluxWebcam, ("state", "live"), ("device", "/dev/video42"), ("label", "Flux Camera")))
        XCTAssertEqual(.live(device: "/dev/video42", label: "Flux Camera"), live)
        let failed = WebcamReply.parse(Packet.of(
            PacketType.fluxWebcam, ("state", "error"), ("message", "v4l2loopback is missing")))
        XCTAssertEqual(.failed(message: "v4l2loopback is missing"), failed)
        XCTAssertEqual(.stop, WebcamReply.parse(Packet.of(PacketType.fluxWebcam, ("state", "stop"))))
        XCTAssertNil(WebcamReply.parse(Packet.of(PacketType.fluxWebcam, ("state", "start"))))
        XCTAssertNil(WebcamReply.parse(Packet.of(PacketType.ping, ("state", "live"))))
    }

    func testWebcamLiveWithoutLabelGetsTheDefaultName() {
        let live = WebcamReply.parse(Packet.of(
            PacketType.fluxWebcam, ("state", "live"), ("device", "/dev/video42")))
        XCTAssertEqual(.live(device: "/dev/video42", label: "Flux Camera"), live)
    }

    func testWebcamConfigReply() {
        let cfg = WebcamReply.parse(Packet(
            type: PacketType.fluxWebcam,
            body: ["state": .string("config"), "config": .object(["brightness": .double(0.2)])]))
        XCTAssertEqual(.config(partial: ["brightness": .double(0.2)], reset: false), cfg)
        let reset = WebcamReply.parse(Packet.of(PacketType.fluxWebcam, ("state", "config"), ("reset", true)))
        XCTAssertEqual(.config(partial: nil, reset: true), reset)
        // Neither a partial nor a reset is not a config change.
        XCTAssertNil(WebcamReply.parse(Packet.of(PacketType.fluxWebcam, ("state", "config"))))
    }

    // MARK: - Mic

    func testMicStartBodyHasTheFormat() throws {
        let p = MicPackets.start(port: 1745)
        XCTAssertEqual(PacketType.fluxMic, p.type)
        XCTAssertEqual("start", p.string("state"))
        XCTAssertEqual(1745, p.int("port"))
        XCTAssertEqual(48_000, p.int("rate"))
        XCTAssertEqual(1, p.int("channels"))
        XCTAssertEqual("s16le", p.string("format"))
        XCTAssertEqual(1745, try XCTUnwrap(Packet.parse(try p.serialize())).int("port"))
        XCTAssertEqual("stop", MicPackets.stop().string("state"))
    }

    func testMicParsesReplies() {
        XCTAssertEqual(
            .live(source: "Flux Microphone"),
            MicReply.parse(Packet.of(PacketType.fluxMic, ("state", "live"), ("source", "Flux Microphone"))))
        XCTAssertEqual(
            .live(source: "Flux Microphone"),
            MicReply.parse(Packet.of(PacketType.fluxMic, ("state", "live"))))
        XCTAssertEqual(
            .failed(message: "no pw-cat"),
            MicReply.parse(Packet.of(PacketType.fluxMic, ("state", "error"), ("message", "no pw-cat"))))
        XCTAssertEqual(.stop, MicReply.parse(Packet.of(PacketType.fluxMic, ("state", "stop"))))
        XCTAssertNil(MicReply.parse(Packet.of(PacketType.fluxMic, ("state", "start"))))
        XCTAssertNil(MicReply.parse(Packet.of(PacketType.fluxWebcam, ("state", "live"))))
    }

    /// Go `TestMicStartCheck` vectors: defaults + every rejection.
    func testMicStartCheck() {
        let ok = MicStartCheck.check(port: 1739, format: "", rate: 0, channels: 0)
        XCTAssertEqual(.success(MicStartCheck.Params(port: 1739, rate: 48_000, channels: 1, format: "s16le")), ok)
        for bad in [
            (0, "s16le", 48_000, 1), (70000, "s16le", 48_000, 1),
            (1739, "f32le", 48_000, 1), (1739, "s16le", 4000, 1),
            (1739, "s16le", 192000, 1), (1739, "s16le", 48_000, 6),
        ] as [(Int, String, Int, Int)] {
            if case .success = MicStartCheck.check(port: bad.0, format: bad.1, rate: bad.2, channels: bad.3) {
                XCTFail("\(bad): want an error")
            }
        }
    }

    // MARK: - Screen

    func testScreenStartBodyHasTheSize() throws {
        let p = ScreenPackets.start(port: 1750, width: 496, height: 1072)
        XCTAssertEqual(PacketType.fluxScreen, p.type)
        XCTAssertEqual("start", p.string("state"))
        XCTAssertEqual(1750, p.int("port"))
        XCTAssertEqual(496, p.int("width"))
        XCTAssertEqual(1072, p.int("height"))
        XCTAssertEqual("h264", p.string("codec"))
        XCTAssertEqual("stop", ScreenPackets.stop().string("state"))
        let back = try XCTUnwrap(Packet.parse(try p.serialize()))
        XCTAssertEqual(496, back.int("width"))
    }

    func testScreenParsesReplies() {
        XCTAssertEqual(
            .live(player: "mpv"),
            ScreenReply.parse(Packet.of(PacketType.fluxScreen, ("state", "live"), ("player", "mpv"))))
        XCTAssertEqual(
            .failed(message: "no mpv"),
            ScreenReply.parse(Packet.of(PacketType.fluxScreen, ("state", "error"), ("message", "no mpv"))))
        XCTAssertEqual(.stop, ScreenReply.parse(Packet.of(PacketType.fluxScreen, ("state", "stop"))))
        XCTAssertNil(ScreenReply.parse(Packet.of(PacketType.fluxScreen, ("state", "start"))))
        XCTAssertNil(ScreenReply.parse(Packet.of(PacketType.fluxMic, ("state", "stop"))))
    }

    // MARK: - Capture shares (photo_dir / scan_dir routing)

    /// The flags Go `handleShare` routes on: `scan` → `scan_dir`, `photo`
    /// → `photo_dir`, `screenshot` (+`photo`, for older `fluxd`) → the
    /// screenshots folder. Android `Share.sendCapture` sends the same map.
    func testScanTextPacket() throws {
        let back = try XCTUnwrap(Packet.parse(try ShareMessage.textPacket("Gate B14", scan: true).serialize()))
        XCTAssertEqual(.text("Gate B14", scan: true), ShareMessage.parse(back))
    }

    func testPhotoAnnouncementCarriesTheFlag() throws {
        let p = ShareMessage.filePacket(
            filename: "IMG_20260925_101500.jpg", totalPayloadSize: 12, payloadSize: 12,
            payloadPort: 1739, extra: [("photo", true)])
        let back = try XCTUnwrap(Packet.parse(try p.serialize()))
        guard case .file(let file) = ShareMessage.parse(back) else {
            return XCTFail("want a file announcement")
        }
        XCTAssertTrue(file.photo)
        XCTAssertFalse(file.scan)
        XCTAssertFalse(file.screenshot)
    }

    func testScreenshotAnnouncementCarriesBothFlags() throws {
        // Android sends photo + screenshot so older fluxd still saves shots.
        let p = ShareMessage.filePacket(
            filename: "shot.jpg", totalPayloadSize: 12, payloadSize: 12,
            payloadPort: 1739, extra: [("photo", true), ("screenshot", true)])
        let back = try XCTUnwrap(Packet.parse(try p.serialize()))
        guard case .file(let file) = ShareMessage.parse(back) else {
            return XCTFail("want a file announcement")
        }
        XCTAssertTrue(file.photo)
        XCTAssertTrue(file.screenshot)
    }

    func testScanPdfAnnouncementCarriesTheFlag() throws {
        let p = ShareMessage.filePacket(
            filename: "scan-20260925-101500.pdf", totalPayloadSize: 12, payloadSize: 12,
            payloadPort: 1739, extra: [("scan", true)])
        let back = try XCTUnwrap(Packet.parse(try p.serialize()))
        guard case .file(let file) = ShareMessage.parse(back) else {
            return XCTFail("want a file announcement")
        }
        XCTAssertTrue(file.scan)
    }
}
