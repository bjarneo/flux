import XCTest
@testable import FluxCore
@testable import FluxProto

/// `FeatureRouter` M4 behavior: desktop media state, desktop media control
/// (`flux media *`), runcommand lists, and `flux.dnd`. Mirrors Android
/// `core/Plugins.kt` (`receiveMpris`, `parseCommands`) and Go
/// `internal/core/{media,handlers,dnd}.go`.
final class MediaRouterTests: XCTestCase {
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

    private func sends(_ actions: [FeatureAction]) -> [Packet] {
        actions.compactMap {
            if case .send(let p) = $0 { return p }
            return nil
        }
    }

    // MARK: - Gates

    func testM4PacketsNeedPairing() {
        var router = FeatureRouter()
        let actions = router.route(
            Packet.of(PacketType.mpris, ("playerList", ["spotify"] as [Any])),
            ctx: ctx(paired: false))
        XCTAssertEqual([.event(.ignored(type: PacketType.mpris, reason: .unpaired))], actions)
    }

    func testMprisRequestNeedsCapability() {
        var router = FeatureRouter()
        var limited = incomingCapabilities
        limited.removeAll { $0 == PacketType.mprisRequest }
        let actions = router.route(
            Packet.of(PacketType.mprisRequest, ("requestPlayerList", true)),
            ctx: ctx(incoming: limited))
        XCTAssertEqual([.event(.ignored(type: PacketType.mprisRequest, reason: .unadvertised))], actions)
    }

    // MARK: - Desktop state (kdeconnect.mpris)

    func testPlayerListReseatsAndAsks() {
        var router = FeatureRouter()
        let actions = router.route(
            Packet.of(PacketType.mpris, ("playerList", ["spotify", "vlc"] as [Any])),
            ctx: ctx())
        XCTAssertEqual([.event(.mediaPlayersChanged(players: ["spotify", "vlc"]))], events(actions).map(FeatureAction.event))
        // Android asks for the new current player's state at once.
        let out = sends(actions)
        XCTAssertEqual(1, out.count)
        XCTAssertEqual(PacketType.mprisRequest, out[0].type)
        XCTAssertEqual("spotify", out[0].string("player"))
        XCTAssertEqual(true, out[0].bool("requestNowPlaying"))
        XCTAssertEqual("spotify", router.mediaCurrent)
    }

    func testPlayerListKeepsCurrent() {
        var router = FeatureRouter()
        _ = router.route(Packet.of(PacketType.mpris, ("playerList", ["spotify", "vlc"] as [Any])), ctx: ctx())
        let actions = router.route(Packet.of(PacketType.mpris, ("playerList", ["vlc", "spotify"] as [Any])), ctx: ctx())
        XCTAssertEqual("spotify", router.mediaCurrent)
        XCTAssertEqual("spotify", sends(actions)[0].string("player"))
    }

    func testEmptyPlayerListClears() {
        var router = FeatureRouter()
        _ = router.route(Packet.of(PacketType.mpris, ("playerList", ["spotify"] as [Any])), ctx: ctx())
        let actions = router.route(Packet.of(PacketType.mpris, ("playerList", [] as [Any])), ctx: ctx())
        XCTAssertEqual([.event(.mediaPlayersChanged(players: []))], events(actions).map(FeatureAction.event))
        XCTAssertEqual([], sends(actions))
        XCTAssertNil(router.mediaCurrent)
    }

    func testNowPlayingEmitsAndSwitches() {
        var router = FeatureRouter()
        let state = Packet.of(
            PacketType.mpris, ("player", "spotify"), ("title", "Song"),
            ("artist", "Band"), ("isPlaying", false), ("pos", 1_000),
            ("length", 200_000), ("canSeek", true))
        let actions = router.route(state, ctx: ctx())
        XCTAssertEqual("spotify", router.mediaCurrent)
        guard case .event(.mediaState(let s)) = actions.first, actions.count == 1 else {
            return XCTFail("expected one mediaState event, got \(actions)")
        }
        XCTAssertEqual("Song", s.title)
        XCTAssertFalse(s.playing)
        // A second player starts playing: control switches to it (Android parity).
        let playing = Packet.of(PacketType.mpris, ("player", "vlc"), ("isPlaying", true))
        let actions2 = router.route(playing, ctx: ctx())
        XCTAssertEqual("vlc", router.mediaCurrent)
        XCTAssertEqual([.event(.mediaState(MprisState(player: "vlc", playing: true)))], actions2)
    }

    func testMprisEmptyIsUnhandled() {
        var router = FeatureRouter()
        XCTAssertEqual(
            [.event(.ignored(type: PacketType.mpris, reason: .unhandled))],
            router.route(Packet(type: PacketType.mpris), ctx: ctx()))
    }

    // MARK: - Desktop control (kdeconnect.mpris.request)

    func testMediaActionRoutes() {
        var router = FeatureRouter()
        for verb in MediaAction.allCases.map(\.rawValue) {
            let actions = router.route(
                Packet.of(PacketType.mprisRequest, ("player", "spotify"), ("action", verb)), ctx: ctx())
            XCTAssertEqual([.event(.mediaActionRequested(player: "spotify", action: verb))], actions, verb)
        }
    }

    func testMediaQueriesRoute() {
        var router = FeatureRouter()
        XCTAssertEqual(
            [.event(.mediaPlayersRequested)],
            router.route(Packet.of(PacketType.mprisRequest, ("requestPlayerList", true)), ctx: ctx()))
        XCTAssertEqual(
            [.event(.mediaStateRequested(player: "spotify"))],
            router.route(Packet.of(PacketType.mprisRequest, ("player", "spotify"), ("requestNowPlaying", true)), ctx: ctx()))
        XCTAssertEqual(
            [.event(.mediaSeekRequested(player: "vlc", positionMs: 5_000))],
            router.route(Packet.of(PacketType.mprisRequest, ("player", "vlc"), ("SetPosition", 5_000)), ctx: ctx()))
        XCTAssertEqual(
            [.event(.mediaVolumeRequested(player: "vlc", volume: 30))],
            router.route(Packet.of(PacketType.mprisRequest, ("player", "vlc"), ("setVolume", 30)), ctx: ctx()))
        XCTAssertEqual(
            [.event(.mediaAlbumArtRequested(player: "spotify", url: "file:///a"))],
            router.route(Packet.of(PacketType.mprisRequest, ("player", "spotify"), ("albumArtUrl", "file:///a")), ctx: ctx()))
        // Empty requests are unhandled, not crashed on.
        XCTAssertEqual(
            [.event(.ignored(type: PacketType.mprisRequest, reason: .unhandled))],
            router.route(Packet(type: PacketType.mprisRequest), ctx: ctx()))
    }

    // MARK: - Commands

    func testCommandListRoutesInOrder() {
        var router = FeatureRouter()
        let list = #"{"b": {"name": "B", "command": "b.sh"}, "a": {"name": "A", "command": "a.sh"}}"#
        let actions = router.route(
            Packet.of(PacketType.runCommand, ("commandList", list), ("canAddCommand", false)), ctx: ctx())
        guard case .event(.commandList(let commands, let canAdd)) = actions.first, actions.count == 1 else {
            return XCTFail("expected one commandList event, got \(actions)")
        }
        XCTAssertEqual(["b", "a"], commands.map(\.key))
        XCTAssertFalse(canAdd)
    }

    func testCommandListMissingIsUnhandled() {
        var router = FeatureRouter()
        XCTAssertEqual(
            [.event(.ignored(type: PacketType.runCommand, reason: .unhandled))],
            router.route(Packet(type: PacketType.runCommand), ctx: ctx()))
    }

    // MARK: - DND

    func testDndRoutes() {
        var router = FeatureRouter()
        XCTAssertEqual(
            [.event(.dndChanged(on: true))],
            router.route(DndMessage.packet(on: true), ctx: ctx()))
        XCTAssertEqual(
            [.event(.dndChanged(on: false))],
            router.route(DndMessage.packet(on: false), ctx: ctx()))
        XCTAssertEqual(
            [.event(.ignored(type: PacketType.fluxDnd, reason: .unhandled))],
            router.route(Packet(type: PacketType.fluxDnd), ctx: ctx()))
    }
}
