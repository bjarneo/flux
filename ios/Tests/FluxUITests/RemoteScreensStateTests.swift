import XCTest
import FluxProto
import FluxStream
@testable import FluxUI

/// Store contract for the reverse-direction remote screens (#1 commands,
/// #2 media): presence tracking, list/state caching, and the loaded flag
/// that decides between the spinner and the empty state.
final class RemoteScreensStateTests: XCTestCase {
    private func sampleCommands() -> [RemoteCommand] {
        [
            RemoteCommand(key: "lock", name: "Lock screen", command: "loginctl lock-session"),
            RemoteCommand(key: "mute", name: "Mute", command: "mute.sh"),
        ]
    }

    func testPairingAddsComputerOnce() {
        var store = RemoteScreensState()
        store.notePaired("archlinux")
        store.notePaired("archlinux")
        XCTAssertEqual(store.computers, ["archlinux"])
    }

    func testCloseRemovesComputerAndItsCachedState() {
        var store = RemoteScreensState()
        store.applyCommands(device: "archlinux", commands: sampleCommands())
        store.applyPlayers(device: "archlinux", players: ["spotify"])
        store.applyMediaState(
            device: "archlinux",
            state: MprisState(player: "spotify", title: "Song", playing: true))
        store.noteClosed("archlinux")
        XCTAssertTrue(store.computers.isEmpty)
        XCTAssertFalse(store.isCommandsLoaded(device: "archlinux"))
        XCTAssertTrue(store.players(for: "archlinux").isEmpty)
        XCTAssertNil(store.mediaState(for: "archlinux"))
    }

    func testCommandsApplyKeepsDesktopOrder() {
        var store = RemoteScreensState()
        store.applyCommands(device: "archlinux", commands: sampleCommands())
        XCTAssertEqual(store.commands(for: "archlinux").map(\.key), ["lock", "mute"])
        XCTAssertTrue(store.isCommandsLoaded(device: "archlinux"))
    }

    func testEmptyListCountsAsLoaded() {
        // An empty list must render "No commands yet", not the spinner:
        // presence of the key (not the count) marks loaded.
        var store = RemoteScreensState()
        XCTAssertFalse(store.isCommandsLoaded(device: "archlinux"))
        store.applyCommands(device: "archlinux", commands: [])
        XCTAssertTrue(store.isCommandsLoaded(device: "archlinux"))
        XCTAssertTrue(store.commands(for: "archlinux").isEmpty)
    }

    func testCommandsApplyImpliesPaired() {
        // Lists can arrive without a preceding `.paired` the app saw
        // (e.g. a race at startup); the computer still lists.
        var store = RemoteScreensState()
        store.applyCommands(device: "archlinux", commands: sampleCommands())
        XCTAssertEqual(store.computers, ["archlinux"])
    }

    func testMediaApplyAndOverwrite() {
        var store = RemoteScreensState()
        store.applyPlayers(device: "archlinux", players: ["spotify", "vlc"])
        XCTAssertEqual(store.players(for: "archlinux"), ["spotify", "vlc"])
        store.applyMediaState(
            device: "archlinux",
            state: MprisState(player: "spotify", title: "One", playing: false))
        store.applyMediaState(
            device: "archlinux",
            state: MprisState(player: "spotify", title: "Two", playing: true))
        let state = store.mediaState(for: "archlinux")
        XCTAssertEqual(state?.title, "Two")
        XCTAssertEqual(state?.playing, true)
    }

    func testUnknownDeviceReadsEmpty() {
        let store = RemoteScreensState()
        XCTAssertTrue(store.commands(for: "archlinux").isEmpty)
        XCTAssertTrue(store.players(for: "archlinux").isEmpty)
        XCTAssertNil(store.mediaState(for: "archlinux"))
    }

    func testMicStatusDefaultsIdleAndSurvivesClose() {
        var store = RemoteScreensState()
        XCTAssertEqual(.idle, store.micStatus(for: "archlinux").phase)
        store.applyMicStatus(
            device: "archlinux",
            status: StreamStatus(phase: .live, message: "Live", deviceId: "archlinux"))
        XCTAssertEqual(.live, store.micStatus(for: "archlinux").phase)
        // A mic apply implies the computer, like commands/media do.
        XCTAssertEqual(["archlinux"], store.computers)
        store.noteClosed("archlinux")
        XCTAssertEqual(.idle, store.micStatus(for: "archlinux").phase)
    }

    func testWebcamStatusDefaultsIdleAndSurvivesClose() {
        var store = RemoteScreensState()
        XCTAssertEqual(.idle, store.webcamStatus(for: "archlinux").phase)
        store.applyWebcamStatus(
            device: "archlinux",
            status: StreamStatus(phase: .live, message: "Live", deviceId: "archlinux"))
        XCTAssertEqual(.live, store.webcamStatus(for: "archlinux").phase)
        // A webcam apply implies the computer, like commands/media/mic do.
        XCTAssertEqual(["archlinux"], store.computers)
        store.noteClosed("archlinux")
        XCTAssertEqual(.idle, store.webcamStatus(for: "archlinux").phase)
    }

    func testScreenStatusDefaultsIdleAndSurvivesClose() {
        var store = RemoteScreensState()
        XCTAssertEqual(.idle, store.screenStatus(for: "archlinux").phase)
        store.applyScreenStatus(
            device: "archlinux",
            status: StreamStatus(phase: .live, message: "Mirrors", deviceId: "archlinux"))
        XCTAssertEqual(.live, store.screenStatus(for: "archlinux").phase)
        // A mirror apply implies the computer, like the other streams do.
        XCTAssertEqual(["archlinux"], store.computers)
        store.noteClosed("archlinux")
        XCTAssertEqual(.idle, store.screenStatus(for: "archlinux").phase)
    }

    func testBrowseDefaultsFreshLoading() {
        let store = RemoteScreensState()
        let state = store.browseState(for: "archlinux")
        XCTAssertTrue(state.loading)
        XCTAssertNil(state.error)
        XCTAssertTrue(state.roots.isEmpty)
        XCTAssertTrue(state.entries.isEmpty)
    }

    func testBrowseApplyDropAndClose() {
        var store = RemoteScreensState()
        let roots = [BrowseRoot(name: "Home", path: "/home/ed")]
        let entries = [BrowseEntry(name: "notes.txt", path: "/home/ed/notes.txt", dir: false, size: 7)]
        store.applyBrowse(
            device: "archlinux",
            state: BrowseViewState(loading: false, roots: roots, path: "/home/ed", entries: entries))
        // A browse apply implies the computer, like the other screens do.
        XCTAssertEqual(["archlinux"], store.computers)
        XCTAssertEqual(entries, store.browseState(for: "archlinux").entries)
        store.dropBrowse(device: "archlinux")
        XCTAssertTrue(store.browseState(for: "archlinux").loading)
        store.applyBrowse(
            device: "archlinux",
            state: BrowseViewState(loading: false, roots: roots, path: "/home/ed", entries: entries))
        store.noteClosed("archlinux")
        XCTAssertTrue(store.computers.isEmpty)
        XCTAssertTrue(store.browseState(for: "archlinux").entries.isEmpty)
    }
}
