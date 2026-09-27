import XCTest
@testable import FluxKit

final class MediaTests: XCTestCase {
    private func mpris(_ body: [String: Any?]) -> Packet { Packet(PacketType.mpris, body) }

    func testPlayerListPicksFirstPlayerAndDropsGoneStates() {
        var m = RemoteMedia()
        _ = m.apply(mpris(["player": "vlc", "title": "Old"]), now: 1)
        XCTAssertEqual(m.current, "vlc")

        let request = m.apply(mpris(["playerList": ["spotify", "firefox"]]), now: 2)
        XCTAssertEqual(m.players, ["spotify", "firefox"])
        XCTAssertEqual(m.current, "spotify")
        XCTAssertEqual(request, "spotify")
        XCTAssertNil(m.states["vlc"])
        XCTAssertNil(m.player)
    }

    func testPlayerListKeepsCurrentPlayerThatStillRuns() {
        var m = RemoteMedia()
        _ = m.apply(mpris(["playerList": ["spotify", "firefox"]]), now: 1)
        m.current = "firefox"
        XCTAssertEqual(m.apply(mpris(["playerList": ["mpv", "firefox"]]), now: 2), "firefox")
        XCTAssertEqual(m.current, "firefox")

        XCTAssertNil(m.apply(mpris(["playerList": []]), now: 3))
        XCTAssertNil(m.current)
    }

    func testStateMergesOnlyTheFieldsThatArrive() {
        var m = RemoteMedia()
        _ = m.apply(mpris(["player": "spotify", "title": "Weightless", "artist": "Marconi Union", "isPlaying": true,
                           "pos": 1000, "length": 480_000, "canSeek": true, "volume": 40]), now: 10)
        _ = m.apply(mpris(["player": "spotify", "isPlaying": false, "pos": 5000]), now: 20)
        let s = m.player
        XCTAssertEqual(s?.title, "Weightless")
        XCTAssertEqual(s?.artist, "Marconi Union")
        XCTAssertEqual(s?.playing, false)
        XCTAssertEqual(s?.position, 5000)
        XCTAssertEqual(s?.length, 480_000)
        XCTAssertEqual(s?.canSeek, true)
        XCTAssertEqual(s?.volume, 40)
        XCTAssertEqual(s?.updatedAt, 20)
    }

    func testPlayingPlayerTakesOverPausedCurrentPlayer() {
        var m = RemoteMedia()
        _ = m.apply(mpris(["player": "firefox", "isPlaying": false]), now: 1)
        _ = m.apply(mpris(["player": "spotify", "isPlaying": true]), now: 2)
        XCTAssertEqual(m.current, "spotify")
        // A playing current player keeps control.
        _ = m.apply(mpris(["player": "firefox", "isPlaying": true]), now: 3)
        XCTAssertEqual(m.current, "spotify")
    }

    func testPositionMovesWhilePlayingAndStopsAtLength() {
        var p = RemotePlayer(name: "spotify")
        p.position = 10_000
        p.length = 12_000
        p.updatedAt = 100
        XCTAssertEqual(p.position(at: 101.5), 10_000)
        p.playing = true
        XCTAssertEqual(p.position(at: 101.5), 11_500)
        XCTAssertEqual(p.position(at: 200), 12_000)
    }

    func testTogglePlayingKeepsThePositionReached() {
        var m = RemoteMedia()
        _ = m.apply(mpris(["player": "spotify", "isPlaying": true, "pos": 1000, "length": 60_000]), now: 10)
        m.togglePlaying(now: 13)
        XCTAssertEqual(m.player?.playing, false)
        XCTAssertEqual(m.player?.position, 4000)
        XCTAssertEqual(m.player?.position(at: 50), 4000)
    }

    func testArtURLLoadsOnlyOverHTTP() {
        var p = RemotePlayer(name: "spotify")
        p.artUrl = "https://i.scdn.co/image/ab67616d"
        XCTAssertNotNil(p.artURL)
        p.artUrl = "file:///home/me/.cache/cover.png"
        XCTAssertNil(p.artURL)
    }
}
