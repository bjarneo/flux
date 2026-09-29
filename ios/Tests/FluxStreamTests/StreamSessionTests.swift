import XCTest
@testable import FluxStream
@testable import FluxProto

/// `StreamSession` behavior: phase transitions mirror Android
/// `MicSession.onPacket` / `WebcamSession.onPacket` / `ScreenSession.onPacket`
/// (device match, active-only live, silent error/stop, webcam config action,
/// notify-only-with-stream stop).
final class StreamSessionTests: XCTestCase {
    private let peer = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    private let other = "cccccccccccccccccccccccccccccccc"

    private final class SentBox {
        var packets: [Packet] = []
    }

    private func session(_ kind: StreamKind) -> (StreamSession, SentBox) {
        let s = StreamSession(kind: kind)
        let box = SentBox()
        s.send = { box.packets.append($0); return true }
        return (s, box)
    }

    // MARK: - Mic

    func testMicLiveErrorStop() {
        let (s, _) = session(.mic)
        s.start(deviceId: peer, waiting: "Waiting…")
        XCTAssertEqual(.connecting, s.current.phase)
        s.connected(message: "Starting…")
        XCTAssertEqual(.starting, s.current.phase)
        s.onPacket(deviceId: peer, packet: Packet.of(PacketType.fluxMic, ("state", "live"), ("source", "Flux Microphone")))
        XCTAssertEqual(.live, s.current.phase)
        s.onPacket(deviceId: peer, packet: Packet.of(PacketType.fluxMic, ("state", "stop")))
        XCTAssertEqual(.idle, s.current.phase)
        XCTAssertEqual(peer, s.current.deviceId)
    }

    func testMicLiveNeedsAnActiveSession() {
        let (s, _) = session(.mic)
        // No start: the reply is for nobody.
        s.onPacket(deviceId: peer, packet: Packet.of(PacketType.fluxMic, ("state", "live")))
        XCTAssertEqual(.idle, s.current.phase)
    }

    func testMicIgnoresOtherDevicesAndKinds() {
        let (s, _) = session(.mic)
        s.start(deviceId: peer, waiting: "Waiting…")
        s.onPacket(deviceId: other, packet: Packet.of(PacketType.fluxMic, ("state", "live")))
        XCTAssertEqual(.connecting, s.current.phase)
        s.onPacket(deviceId: peer, packet: Packet.of(PacketType.fluxWebcam, ("state", "live")))
        XCTAssertEqual(.connecting, s.current.phase)
        s.onPacket(deviceId: peer, packet: Packet.of(PacketType.fluxMic, ("state", "start")))
        XCTAssertEqual(.connecting, s.current.phase)
    }

    func testMicErrorEndsSilent() {
        let (s, sent) = session(.mic)
        s.start(deviceId: peer, waiting: "Waiting…")
        s.onPacket(deviceId: peer, packet: Packet.of(PacketType.fluxMic, ("state", "error"), ("message", "no pw-cat")))
        XCTAssertEqual(.error, s.current.phase)
        XCTAssertEqual("no pw-cat", s.current.message)
        XCTAssertTrue(sent.packets.isEmpty, "the computer already knows; no stop goes back")
    }

    func testStopNotifiesOnlyWithAStream() {
        let (s, sent) = session(.mic)
        s.start(deviceId: peer, waiting: "Waiting…")
        s.stop(notify: true)
        XCTAssertTrue(sent.packets.isEmpty, "nothing flowed yet; no stop goes out")
        s.start(deviceId: peer, waiting: "Waiting…")
        s.connected(message: "Starting…")
        s.stop(notify: true)
        XCTAssertEqual([PacketType.fluxMic], sent.packets.map(\.type))
        XCTAssertEqual("stop", sent.packets.first?.string("state"))
    }

    func testMarkLiveNeedsActiveSessionForThisDevice() {
        // The app maps parsed runner live events here (no raw packet).
        let (s, _) = session(.mic)
        s.markLive(deviceId: peer, message: "Live")
        XCTAssertEqual(.idle, s.current.phase)
        s.start(deviceId: peer, waiting: "Waiting…")
        s.markLive(deviceId: other, message: "Live")
        XCTAssertEqual(.connecting, s.current.phase)
        s.markLive(deviceId: peer, message: "Live on peer as Flux Microphone")
        XCTAssertEqual(.live, s.current.phase)
        XCTAssertEqual("Live on peer as Flux Microphone", s.current.message)
    }

    func testGenerationCountsStartsAndStops() {
        let (s, _) = session(.mic)
        XCTAssertEqual(0, s.generation)
        // `start` stops first (Android parity), so it bumps twice.
        s.start(deviceId: peer, waiting: "Waiting…")
        XCTAssertEqual(2, s.generation)
        s.stop(notify: false)
        XCTAssertEqual(3, s.generation)
    }

    func testMicPreferencesRoundTrip() {
        let store = UserDefaults(suiteName: "org.omarchy.flux.stream-tests")!
        store.removePersistentDomain(forName: "org.omarchy.flux.stream-tests")
        XCTAssertFalse(MicPreferences.load(store: store).withWebcam)
        MicPreferences(withWebcam: true).save(store: store)
        XCTAssertTrue(MicPreferences.load(store: store).withWebcam)
        store.removePersistentDomain(forName: "org.omarchy.flux.stream-tests")
    }

    // MARK: - Webcam

    func testWebcamLiveAndStop() {
        let (s, _) = session(.webcam)
        s.start(deviceId: peer, waiting: "Waiting…")
        s.connected(message: "Starting…")
        s.onPacket(deviceId: peer, packet: Packet.of(
            PacketType.fluxWebcam, ("state", "live"), ("device", "/dev/video42"), ("label", "Flux Camera")))
        XCTAssertEqual(.live, s.current.phase)
        s.onPacket(deviceId: peer, packet: Packet.of(PacketType.fluxWebcam, ("state", "stop")))
        XCTAssertEqual(.idle, s.current.phase)
    }

    func testWebcamConfigReturnsAnAction() {
        let (s, _) = session(.webcam)
        s.start(deviceId: peer, waiting: "Waiting…")
        let action = s.onPacket(deviceId: peer, packet: Packet(
            type: PacketType.fluxWebcam,
            body: ["state": .string("config"), "reset": .bool(true)]))
        XCTAssertEqual(StreamConfigAction(partial: nil, reset: true), action)
        XCTAssertEqual(.connecting, s.current.phase, "a config change is not a status change")
    }

    // MARK: - Screen

    func testScreenLiveAndStop() {
        let (s, _) = session(.screen)
        s.start(deviceId: peer, waiting: "Waiting…")
        s.connected(message: "Starting…")
        s.onPacket(deviceId: peer, packet: Packet.of(PacketType.fluxScreen, ("state", "live"), ("player", "mpv")))
        XCTAssertEqual(.live, s.current.phase)
        s.onPacket(deviceId: peer, packet: Packet.of(PacketType.fluxScreen, ("state", "error"), ("message", "no mpv")))
        XCTAssertEqual(.error, s.current.phase)
        XCTAssertEqual("no mpv", s.current.message)
    }
}
