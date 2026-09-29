import XCTest
@testable import FluxProto

/// M4 packet vectors: mpris state + requests, runcommand lists, telephony
/// events, flux.dnd. Field shapes mirror `internal/core/media.go`,
/// `internal/core/handlers.go` (`handleRunCommand`), `internal/core/telephony.go`,
/// `internal/core/dnd.go`, Android `core/Calls.kt` + `core/Plugins.kt`, and
/// `cmd/flux/main.go` (media verbs) — asserted through serialize/parse
/// round-trips.
final class MediaCallsTests: XCTestCase {
    // MARK: - Media actions

    func testMediaActionVerbs() {
        // The six verbs Go PhoneMediaAction accepts (cmd/flux maps onto them).
        XCTAssertEqual(
            ["PlayPause", "Play", "Pause", "Next", "Previous", "Stop"],
            MediaAction.allCases.map(\.rawValue))
        for v in MediaAction.allCases { XCTAssertTrue(MediaAction.isValid(v.rawValue)) }
        for bad in ["", "play-pause", "play", "Play-Pause", "prev", "Toggle", "PLAY"] {
            XCTAssertFalse(MediaAction.isValid(bad), bad)
        }
    }

    // MARK: - mpris.request builders (phone→desktop)

    func testMprisRequestBuilders() throws {
        let list = try XCTUnwrap(Packet.parse(try MprisMessage.requestPlayerList().serialize()))
        XCTAssertEqual(PacketType.mprisRequest, list.type)
        XCTAssertEqual(true, list.bool("requestPlayerList"))

        let now = try XCTUnwrap(Packet.parse(try MprisMessage.requestNowPlaying(player: "spotify").serialize()))
        XCTAssertEqual("spotify", now.string("player"))
        XCTAssertEqual(true, now.bool("requestNowPlaying"))
        XCTAssertEqual(true, now.bool("requestVolume"))

        let act = try XCTUnwrap(MprisMessage.action(player: "spotify", action: "PlayPause"))
        let actBack = try XCTUnwrap(Packet.parse(try act.serialize()))
        XCTAssertEqual("PlayPause", actBack.string("action"))
        XCTAssertNil(MprisMessage.action(player: "spotify", action: "play-pause"))

        let seek = try XCTUnwrap(Packet.parse(try MprisMessage.seek(player: "vlc", positionMs: 12_000).serialize()))
        // Android sends capital-S SetPosition, which Go reads.
        XCTAssertEqual(12_000, seek.long("SetPosition"))

        let vol = try XCTUnwrap(Packet.parse(try MprisMessage.setVolume(player: "vlc", volume: 80).serialize()))
        XCTAssertEqual(80, vol.int("setVolume"))
    }

    // MARK: - mpris state parse (desktop→phone)

    func testMprisStateParse() throws {
        // Go sendNowPlaying shape.
        let p = Packet.of(
            PacketType.mpris,
            ("playerList", ["spotify"] as [Any]),
            ("player", "spotify"), ("title", "Song"), ("artist", "Band"),
            ("album", "Record"), ("isPlaying", true), ("pos", 1_000),
            ("length", 200_000), ("volume", 80), ("canPlay", true),
            ("canPause", true), ("canGoNext", true), ("canGoPrevious", false),
            ("canSeek", true), ("albumArtUrl", "file:///art"))
        let back = try XCTUnwrap(Packet.parse(try Packet(type: p.type, body: p.body).serialize()))
        let update = try XCTUnwrap(MprisMessage.parse(back))
        XCTAssertEqual(["spotify"], update.players)
        let s = try XCTUnwrap(update.state)
        XCTAssertEqual("spotify", s.player)
        XCTAssertEqual("Song", s.title)
        XCTAssertEqual("Band", s.artist)
        XCTAssertEqual("Record", s.album)
        XCTAssertTrue(s.playing)
        XCTAssertEqual(1_000, s.position)
        XCTAssertEqual(200_000, s.length)
        XCTAssertEqual(80, s.volume)
        XCTAssertTrue(s.canSeek)
        XCTAssertEqual("file:///art", s.albumArtUrl)
    }

    func testMprisPlayerListOnly() throws {
        // Go sendPlayerList shape (no player): list only, like test_peer.py.
        let p = Packet.of(PacketType.mpris, ("playerList", ["spotify"] as [Any]), ("supportAlbumArtPayload", false))
        let update = try XCTUnwrap(MprisMessage.parse(p))
        XCTAssertEqual(["spotify"], update.players)
        XCTAssertNil(update.state)
        // Neither list nor player: unhandled.
        XCTAssertNil(MprisMessage.parse(Packet(type: PacketType.mpris)))
        XCTAssertNil(MprisMessage.parse(Packet(type: PacketType.ping)))
    }

    func testPhoneStateAnswerPackets() throws {
        let players = try XCTUnwrap(Packet.parse(try MprisMessage.playerListPacket(["Music"]).serialize()))
        XCTAssertEqual(["Music"], players.strings("playerList"))
        let s = MprisState(player: "Music", title: "Tone", artist: "Band", playing: true, position: 5_000, length: 60_000, canSeek: true)
        let state = try XCTUnwrap(MprisMessage.parse(try XCTUnwrap(Packet.parse(try MprisMessage.statePacket(s).serialize()))))
        XCTAssertEqual("Tone", state.state?.title)
        XCTAssertEqual(true, state.state?.playing)
        XCTAssertEqual(5_000, state.state?.position)
    }

    // MARK: - mpris.request parse (desktop→phone, flux media *)

    func testMprisRequestParse() {
        XCTAssertEqual(.playerList, MprisRequest.parse(Packet.of(PacketType.mprisRequest, ("requestPlayerList", true))))
        XCTAssertEqual(
            .action(player: "spotify", action: "Pause"),
            MprisRequest.parse(Packet.of(PacketType.mprisRequest, ("player", "spotify"), ("action", "Pause"))))
        XCTAssertEqual(
            .seek(player: "vlc", positionMs: 9_000),
            MprisRequest.parse(Packet.of(PacketType.mprisRequest, ("player", "vlc"), ("SetPosition", 9_000))))
        XCTAssertEqual(
            .seek(player: "vlc", positionMs: 9_000),
            MprisRequest.parse(Packet.of(PacketType.mprisRequest, ("player", "vlc"), ("Seek", 9_000))))
        XCTAssertEqual(
            .setVolume(player: "vlc", volume: 42),
            MprisRequest.parse(Packet.of(PacketType.mprisRequest, ("player", "vlc"), ("setVolume", 42))))
        XCTAssertEqual(
            .nowPlaying(player: "spotify"),
            MprisRequest.parse(Packet.of(PacketType.mprisRequest, ("player", "spotify"), ("requestNowPlaying", true))))
        XCTAssertEqual(
            .nowPlaying(player: "spotify"),
            MprisRequest.parse(Packet.of(PacketType.mprisRequest, ("player", "spotify"), ("requestVolume", true))))
        XCTAssertEqual(
            .albumArt(player: "spotify", url: "file:///a"),
            MprisRequest.parse(Packet.of(PacketType.mprisRequest, ("player", "spotify"), ("albumArtUrl", "file:///a"))))
        // Hardware shape (Go PhoneMediaAction with no published phone
        // state, v1/D13): empty or missing player still parses — the
        // bridge no-ops on the unknown player. Empty body and other
        // types stay unhandled.
        XCTAssertEqual(
            .action(player: "", action: "Pause"),
            MprisRequest.parse(Packet.of(PacketType.mprisRequest, ("action", "Pause"))))
        XCTAssertEqual(
            .action(player: "", action: "PlayPause"),
            MprisRequest.parse(Packet.of(PacketType.mprisRequest, ("player", ""), ("action", "PlayPause"))))
        XCTAssertNil(MprisRequest.parse(Packet(type: PacketType.mprisRequest)))
        XCTAssertNil(MprisRequest.parse(Packet(type: PacketType.mpris)))
    }

    // MARK: - runcommand list

    func testRunCommandListParseKeepsOrder() throws {
        // Go sendCommandList shape: the list is a JSON string in config order.
        let list = #"{"lock": {"name": "Lock screen", "command": "loginctl lock-session"}, "term": {"name": "Terminal", "command": "xterm"}, "mute": {"name": "Mute", "command": "mute.sh"}}"#
        let p = Packet.of(PacketType.runCommand, ("commandList", list), ("canAddCommand", false))
        let back = try XCTUnwrap(Packet.parse(try p.serialize()))
        let parsed = try XCTUnwrap(RunCommandMessage.parseList(back))
        XCTAssertEqual(["lock", "term", "mute"], parsed.commands.map(\.key))
        XCTAssertEqual(["Lock screen", "Terminal", "Mute"], parsed.commands.map(\.name))
        XCTAssertEqual("xterm", parsed.commands[1].command)
        XCTAssertFalse(parsed.canAddCommand)
    }

    func testRunCommandListEscapesAndSkips() {
        let list = #"{"q": {"name": "Say \"hi\"", "command": "echo \\m"}, "n": 42, "e": {}}"#
        let p = Packet.of(PacketType.runCommand, ("commandList", list), ("canAddCommand", true))
        let parsed = RunCommandMessage.parseList(p)!
        XCTAssertEqual(["q", "e"], parsed.commands.map(\.key))
        XCTAssertEqual("Say \"hi\"", parsed.commands[0].name)
        XCTAssertEqual(#"echo \m"#, parsed.commands[0].command)
        // Non-object values are dropped (Android parseCommands parity);
        // an empty object keeps its key as the name.
        XCTAssertEqual("e", parsed.commands[1].name)
        XCTAssertEqual("", parsed.commands[1].command)
        XCTAssertTrue(parsed.canAddCommand)
    }

    func testRunCommandListMalformedIsEmpty() {
        // A bad list is unhandled-as-empty (Android shows "No commands"), not fatal.
        let parsed = RunCommandMessage.parseList(Packet.of(PacketType.runCommand, ("commandList", "not json")))
        XCTAssertEqual([], parsed?.commands)
        XCTAssertEqual(false, parsed?.canAddCommand)
        XCTAssertNil(RunCommandMessage.parseList(Packet(type: PacketType.runCommand)))
        XCTAssertNil(RunCommandMessage.parseList(Packet(type: PacketType.ping)))
    }

    func testRunCommandBuilders() throws {
        let req = try XCTUnwrap(Packet.parse(try RunCommandMessage.requestList().serialize()))
        XCTAssertEqual(PacketType.runCommandRequest, req.type)
        XCTAssertEqual(true, req.bool("requestCommandList"))
        let run = try XCTUnwrap(RunCommandMessage.run(key: "lock"))
        let back = try XCTUnwrap(Packet.parse(try run.serialize()))
        XCTAssertEqual("lock", back.string("key"))
        XCTAssertNil(RunCommandMessage.run(key: ""))
    }

    // MARK: - Calls

    func testCallTrackerLifecycle() {
        var t = CallTracker()
        // Incoming call, answered, hung up.
        XCTAssertEqual([CallEvent("ringing")], t.onState(.ringing))
        XCTAssertEqual([CallEvent("talking")], t.onState(.offHook))
        XCTAssertEqual([CallEvent("talking", cancel: true)], t.onState(.idle))
        // Missed call: ringing straight to idle.
        XCTAssertEqual([CallEvent("ringing")], t.onState(.ringing))
        XCTAssertEqual([CallEvent("missedCall"), CallEvent("ringing", cancel: true)], t.onState(.idle))
        // Dialed call: idle straight to off-hook.
        XCTAssertEqual([CallEvent("talking")], t.onState(.offHook))
        XCTAssertEqual([CallEvent("talking", cancel: true)], t.onState(.idle))
        // Repeats send nothing.
        XCTAssertEqual([], t.onState(.idle))
    }

    func testCallerNameFallback() {
        // Go TestCaller vectors.
        XCTAssertEqual("Mom", CallPackets.caller(phoneNumber: "+47 123", contactName: "Mom"))
        XCTAssertEqual("+47 123", CallPackets.caller(phoneNumber: "+47 123", contactName: nil))
        XCTAssertEqual("Unknown caller", CallPackets.caller(phoneNumber: nil, contactName: "  "))
        XCTAssertEqual("Unknown caller", CallPackets.caller(phoneNumber: " ", contactName: nil))
    }

    func testCallPacketBodies() throws {
        let ringing = try XCTUnwrap(Packet.parse(try CallPackets.packet(
            event: CallEvent("ringing"), phoneNumber: " +4712345678 ", contactName: "Mom").serialize()))
        XCTAssertEqual(PacketType.telephony, ringing.type)
        XCTAssertEqual("ringing", ringing.string("event"))
        XCTAssertEqual("+4712345678", ringing.string("phoneNumber"))
        XCTAssertEqual("Mom", ringing.string("contactName"))
        XCTAssertNil(ringing.body["isCancel"])

        // No number and no name: the fallback goes on the wire (Android parity).
        let unknown = CallPackets.packet(event: CallEvent("missedCall"))
        XCTAssertEqual("Unknown caller", unknown.string("contactName"))
        XCTAssertNil(unknown.string("phoneNumber"))

        // Cancel flag only when the event ends.
        let end = CallPackets.packet(event: CallEvent("talking", cancel: true), phoneNumber: "+47")
        XCTAssertEqual(true, end.bool("isCancel"))
    }

    func testIsCancelFlex() {
        func cancel(_ v: JSONValue?) -> Bool {
            var p = Packet(type: PacketType.telephony)
            if let v { p.body["isCancel"] = v }
            return CallPackets.isCancel(p)
        }
        XCTAssertTrue(cancel(.bool(true)))
        XCTAssertTrue(cancel(.integer(1)))
        XCTAssertTrue(cancel(.string("true")))
        XCTAssertTrue(cancel(.string("1")))
        XCTAssertFalse(cancel(.bool(false)))
        XCTAssertFalse(cancel(.integer(0)))
        XCTAssertFalse(cancel(.string("0")))
        XCTAssertFalse(cancel(.string("yes")))
        XCTAssertFalse(cancel(.string("True")))
        XCTAssertFalse(cancel(nil))
        XCTAssertFalse(CallPackets.isCancel(Packet(type: PacketType.ping)))
    }

    // MARK: - DND

    func testDndRoundTrip() throws {
        let on = try XCTUnwrap(Packet.parse(try DndMessage.packet(on: true).serialize()))
        XCTAssertEqual(true, DndMessage.parse(on))
        let off = try XCTUnwrap(Packet.parse(try DndMessage.packet(on: false).serialize()))
        XCTAssertEqual(false, DndMessage.parse(off))
        XCTAssertNil(DndMessage.parse(Packet(type: PacketType.fluxDnd)))
        XCTAssertNil(DndMessage.parse(Packet.of(PacketType.fluxDnd, ("on", "yes"))))
        XCTAssertNil(DndMessage.parse(Packet(type: PacketType.ping)))
    }

    func testDndGuardLocalChanges() {
        // Port of Go TestDndGuardLocalChanges (seconds → ms).
        var g = DndGuard()
        XCTAssertFalse(g.local(on: false, nowMs: 1_000_000))
        XCTAssertFalse(g.local(on: false, nowMs: 1_000_000))
        XCTAssertTrue(g.local(on: true, nowMs: 1_000_000))
        XCTAssertFalse(g.local(on: true, nowMs: 1_000_000))
    }

    func testDndGuardNoEcho() {
        // Port of Go TestDndGuardNoEcho.
        var g = DndGuard()
        _ = g.local(on: false, nowMs: 1_000_000)
        XCTAssertTrue(g.remote(on: true, nowMs: 1_000_000))
        XCTAssertFalse(g.local(on: false, nowMs: 1_001_000))
        XCTAssertFalse(g.local(on: true, nowMs: 1_002_000))
        XCTAssertFalse(g.remote(on: true, nowMs: 1_003_000))
        XCTAssertTrue(g.local(on: false, nowMs: 1_010_000))
    }

    func testDndGuardFailedApply() {
        // Port of Go TestDndGuardFailedApply.
        var g = DndGuard()
        _ = g.local(on: false, nowMs: 1_000_000)
        _ = g.remote(on: true, nowMs: 1_000_000)
        XCTAssertTrue(g.local(on: false, nowMs: 1_000_000 + DndGuard.settleMs + 1_000))
    }

    func testDndGuardRemoteFirst() {
        // Port of Go TestDndGuardRemoteFirst.
        var g = DndGuard()
        XCTAssertTrue(g.remote(on: true, nowMs: 1_000_000))
        XCTAssertFalse(g.local(on: true, nowMs: 1_000_000))
    }
}
