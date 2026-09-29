import XCTest
@testable import FluxCore
@testable import FluxProto

/// `FeatureRouter` M5 behavior: desktop answers to `flux.webcam`
/// (live/error/stop/config), `flux.mic`, and `flux.screen`. Mirrors Android
/// `WebcamSession.onPacket` / `MicSession.onPacket` /
/// `ScreenSession.onPacket` reply parsing and Go `handleWebcam` /
/// `handleMic` / `handleScreen` state coverage.
final class StreamRouterTests: XCTestCase {
    private func ctx(
        paired: Bool = true,
        incoming: [String] = incomingCapabilities,
        nowMs: Int64 = 1_790_000_000_000
    ) -> FeatureContext {
        FeatureContext(
            peerId: "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", peerName: "omarchy-xps",
            paired: paired, incoming: incoming, clipboardSync: false,
            lastLocalClipMs: 0, nowMs: nowMs
        )
    }

    private func events(_ actions: [FeatureAction]) -> [FeatureEvent] {
        actions.compactMap {
            if case .event(let e) = $0 { return e }
            return nil
        }
    }

    // MARK: - Gates

    func testM5PacketsNeedPairing() {
        var router = FeatureRouter()
        for p in [
            Packet.of(PacketType.fluxWebcam, ("state", "live")),
            Packet.of(PacketType.fluxMic, ("state", "stop")),
            Packet.of(PacketType.fluxScreen, ("state", "stop")),
        ] {
            XCTAssertEqual(
                [.event(.ignored(type: p.type, reason: .unpaired))],
                router.route(p, ctx: ctx(paired: false)))
        }
    }

    func testM5PacketsNeedCapability() {
        var router = FeatureRouter()
        var limited = incomingCapabilities
        limited.removeAll { $0 == PacketType.fluxMic }
        XCTAssertEqual(
            [.event(.ignored(type: PacketType.fluxMic, reason: .unadvertised))],
            router.route(Packet.of(PacketType.fluxMic, ("state", "stop")), ctx: ctx(incoming: limited)))
    }

    // MARK: - Webcam replies

    func testWebcamLiveRoutes() {
        var router = FeatureRouter()
        XCTAssertEqual(
            [.webcamLive(device: "/dev/video42", label: "Flux Camera")],
            events(router.route(
                Packet.of(PacketType.fluxWebcam, ("state", "live"), ("device", "/dev/video42")),
                ctx: ctx())))
    }

    func testWebcamErrorAndStopRoute() {
        var router = FeatureRouter()
        XCTAssertEqual(
            [.webcamError(message: "no loopback")],
            events(router.route(
                Packet.of(PacketType.fluxWebcam, ("state", "error"), ("message", "no loopback")),
                ctx: ctx())))
        XCTAssertEqual(
            [.webcamStopped],
            events(router.route(Packet.of(PacketType.fluxWebcam, ("state", "stop")), ctx: ctx())))
    }

    func testWebcamConfigRoutes() {
        var router = FeatureRouter()
        let actions = router.route(
            Packet(type: PacketType.fluxWebcam, body: [
                "state": .string("config"),
                "config": .object(["brightness": .double(0.2)]),
            ]),
            ctx: ctx())
        XCTAssertEqual([.event(.webcamConfig(reset: false, config: ["brightness": .double(0.2)]))], actions)
        XCTAssertEqual(
            [.webcamConfig(reset: true, config: nil)],
            events(router.route(
                Packet.of(PacketType.fluxWebcam, ("state", "config"), ("reset", true)),
                ctx: ctx())))
    }

    func testWebcamStartIsUnhandled() {
        // A start arriving phone-side is meaningless (the phone announces).
        var router = FeatureRouter()
        XCTAssertEqual(
            [.event(.ignored(type: PacketType.fluxWebcam, reason: .unhandled))],
            router.route(
                Packet.of(PacketType.fluxWebcam, ("state", "start"), ("port", 1742)),
                ctx: ctx()))
    }

    // MARK: - Mic replies

    func testMicRepliesRoute() {
        var router = FeatureRouter()
        XCTAssertEqual(
            [.micLive(source: "Flux Microphone")],
            events(router.route(Packet.of(PacketType.fluxMic, ("state", "live")), ctx: ctx())))
        XCTAssertEqual(
            [.micError(message: "no pw-cat")],
            events(router.route(
                Packet.of(PacketType.fluxMic, ("state", "error"), ("message", "no pw-cat")),
                ctx: ctx())))
        XCTAssertEqual(
            [.micStopped],
            events(router.route(Packet.of(PacketType.fluxMic, ("state", "stop")), ctx: ctx())))
        XCTAssertEqual(
            [.event(.ignored(type: PacketType.fluxMic, reason: .unhandled))],
            router.route(Packet.of(PacketType.fluxMic, ("state", "start")), ctx: ctx()))
    }

    // MARK: - Screen replies

    func testScreenRepliesRoute() {
        var router = FeatureRouter()
        XCTAssertEqual(
            [.screenLive(player: "mpv")],
            events(router.route(
                Packet.of(PacketType.fluxScreen, ("state", "live"), ("player", "mpv")),
                ctx: ctx())))
        XCTAssertEqual(
            [.screenError(message: "no mpv")],
            events(router.route(
                Packet.of(PacketType.fluxScreen, ("state", "error"), ("message", "no mpv")),
                ctx: ctx())))
        XCTAssertEqual(
            [.screenStopped],
            events(router.route(Packet.of(PacketType.fluxScreen, ("state", "stop")), ctx: ctx())))
        XCTAssertEqual(
            [.event(.ignored(type: PacketType.fluxScreen, reason: .unhandled))],
            router.route(Packet.of(PacketType.fluxScreen, ("state", "start")), ctx: ctx()))
    }
}
