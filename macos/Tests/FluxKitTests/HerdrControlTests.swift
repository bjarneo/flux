import XCTest
@testable import FluxKit

/// Ported from HerdrTest.kt of the Android app: terminals, workspaces,
/// kinds, and the create, close, and input packets.
final class HerdrControlTests: XCTestCase {
    private func body(_ json: String) -> [String: JSONValue] {
        Packet.parse(#"{"id":1,"type":"flux.herdr","body":\#(json)}"#)!.body
    }

    /// The body of a packet as the Android app and fluxd write it.
    private func wire(_ json: String) -> [String: JSONValue] {
        JSONValue.parse(Data(json.utf8))!.object!
    }

    func testParsesTerminalsWorkspacesAndKinds() throws {
        let s = try XCTUnwrap(HerdrWire.state(body(#"""
        {"kind":"state","enabled":true,"running":true,"control":true,"terminals":true,"agents":[],
        "panes":[{"pane":"w1:p2","title":"npm run dev","project":"web","workspace":"web"},{"title":"no pane"}],
        "workspaces":[{"id":"w1","label":"web","cwd":"/src/web"},{"id":"w2"},{"label":"no id"}],
        "kinds":["claude","","codex"]}
        """#)))
        XCTAssertTrue(s.control)
        XCTAssertTrue(s.terminals)
        XCTAssertEqual(s.panes, [HerdrTerminal(pane: "w1:p2", title: "npm run dev", project: "web", workspace: "web")])
        XCTAssertEqual(s.terminal("w1:p2"), HerdrTerminal(pane: "w1:p2", title: "npm run dev", project: "web", workspace: "web"))
        XCTAssertNil(s.terminal("w9:p9"))
        XCTAssertEqual(s.workspaces, [HerdrWorkspace(id: "w1", label: "web", cwd: "/src/web"), HerdrWorkspace(id: "w2", label: "w2")],
                       "a workspace needs an id, and its id is the label when it has none")
        XCTAssertEqual(s.kinds, ["claude", "codex"], "an empty kind is dropped")
    }

    func testGatesTheFieldsLikeAndroid() throws {
        let noControl = try XCTUnwrap(HerdrWire.state(body(#"""
        {"kind":"state","enabled":true,"running":true,"control":false,"terminals":true,"panes":[{"pane":"w1:p2"}],
        "workspaces":[{"id":"w1"}],"kinds":["claude"]}
        """#)))
        XCTAssertFalse(noControl.terminals, "terminals need control")
        XCTAssertTrue(noControl.panes.isEmpty)
        XCTAssertTrue(noControl.workspaces.isEmpty, "workspaces need control")
        XCTAssertTrue(noControl.kinds.isEmpty, "kinds need control")

        let noTerminals = try XCTUnwrap(HerdrWire.state(body(#"""
        {"kind":"state","enabled":true,"running":true,"control":true,"terminals":false,"panes":[{"pane":"w1:p2"}],
        "workspaces":[{"id":"w1"}],"kinds":["claude"]}
        """#)))
        XCTAssertTrue(noTerminals.panes.isEmpty, "panes need terminals")
        XCTAssertEqual(noTerminals.workspaces.map(\.id), ["w1"])
        XCTAssertEqual(noTerminals.kinds, ["claude"])

        let off = try XCTUnwrap(HerdrWire.state(body(#"{"kind":"state","enabled":false,"running":true,"control":true,"terminals":true}"#)))
        XCTAssertFalse(off.control)
        XCTAssertFalse(off.terminals, "a computer with herdr off has no terminals")

        let old = try XCTUnwrap(HerdrWire.state(body(#"{"kind":"state","enabled":true,"running":true,"control":true,"agents":[]}"#)))
        XCTAssertFalse(old.terminals, "an older fluxd without the field has no terminals")
        XCTAssertTrue(old.kinds.isEmpty)
    }

    func testParsesCreatedAndClosed() {
        XCTAssertEqual(HerdrWire.done(body(#"{"kind":"created","what":"agent","pane":"w4:p1"}"#)),
                       HerdrDone(action: "create", pane: "w4:p1", error: nil))
        XCTAssertEqual(HerdrWire.done(body(#"{"kind":"created","error":"The folder /x does not exist"}"#)),
                       HerdrDone(action: "create", pane: nil, error: "The folder /x does not exist"))
        XCTAssertEqual(HerdrWire.done(body(#"{"kind":"closed","pane":"w4:p1"}"#)),
                       HerdrDone(action: "close", pane: "w4:p1", error: nil))
        XCTAssertEqual(HerdrWire.done(body(#"{"kind":"closed","pane":"w4:p1","error":""}"#))?.error, nil, "an empty error is no error")
        XCTAssertNil(HerdrWire.done(body(#"{"kind":"sent","pane":"w4:p1"}"#)))
    }

    func testTerminalKeys() {
        XCTAssertTrue(HerdrWire.terminalKeys.contains("ctrl+c"))
        XCTAssertTrue(HerdrWire.terminalKeys.contains("ctrl+a"))
        XCTAssertTrue(HerdrWire.terminalKeys.contains("ctrl+z"))
        XCTAssertFalse(HerdrWire.terminalKeys.contains("f1"))
        XCTAssertFalse(HerdrWire.terminalKeys.contains("y"), "a terminal types letters as text")
        XCTAssertFalse(HerdrWire.allowedKeys.contains("ctrl+c"))
        XCTAssertEqual(HerdrWire.terminalKeys.count, 10 + 26)
        XCTAssertTrue(HerdrWire.allowedInput(text: "ls", keys: []), "an input can be text alone")
        XCTAssertTrue(HerdrWire.allowedInput(text: "", keys: ["ctrl+c"]))
        XCTAssertFalse(HerdrWire.allowedInput(text: "", keys: []), "an input needs text or keys")
        XCTAssertFalse(HerdrWire.allowedInput(text: "x", keys: Array(repeating: "up", count: 9)), "fluxd takes at most 8 keys")
        XCTAssertFalse(HerdrWire.allowedInput(text: "x", keys: ["2"]), "digits are text in a terminal")
    }

    func testPacketsMatchAndroid() {
        XCTAssertEqual(HerdrWire.read(pane: "w5:p1").body, wire(#"{"kind":"read","pane":"w5:p1","lines":1000,"format":"ansi"}"#))
        XCTAssertEqual(HerdrWire.input(pane: "w1:p2", text: "ls", keys: ["enter"]).body,
                       wire(#"{"kind":"input","pane":"w1:p2","text":"ls","keys":["enter"]}"#))
        XCTAssertEqual(HerdrWire.input(pane: "w1:p2", text: "", keys: ["ctrl+c"]).body,
                       wire(#"{"kind":"input","pane":"w1:p2","text":"","keys":["ctrl+c"]}"#))
        XCTAssertEqual(HerdrWire.input(pane: "w1:p2", text: "ls", keys: []).body,
                       wire(#"{"kind":"input","pane":"w1:p2","text":"ls","keys":[]}"#))
        XCTAssertEqual(HerdrWire.create(what: "agent", agent: "claude", cwd: " ~/Code/x ", workspace: "w3").body,
                       wire(#"{"kind":"create","what":"agent","agent":"claude","cwd":"~/Code/x","workspace":"w3"}"#))
        XCTAssertEqual(HerdrWire.create(what: "terminal", agent: "", cwd: "", workspace: "").body,
                       wire(#"{"kind":"create","what":"terminal","agent":"","cwd":"","workspace":""}"#))
        XCTAssertEqual(HerdrWire.close(pane: "w4:p1").body, wire(#"{"kind":"close","pane":"w4:p1"}"#))
        XCTAssertEqual(HerdrWire.close(pane: "w4:p1").type, "flux.herdr")
    }

    func testTimeoutsMatchAndroid() {
        XCTAssertEqual(HerdrPlugin.readTimeout, .seconds(15))
        XCTAssertEqual(HerdrPlugin.createTimeout, .seconds(60))
        XCTAssertEqual(HerdrPlugin.replyTimeout, .seconds(10))
        XCTAssertEqual(HerdrPlugin.closeTimeout, .seconds(10))
        XCTAssertEqual(HerdrPlugin.rereadDelay, .milliseconds(700))
        XCTAssertEqual(HerdrWire.readLines, 1000)
    }

    // MARK: Plugin

    private func packet(_ json: String) -> Packet { Packet.parse(#"{"id":1,"type":"flux.herdr","body":\#(json)}"#)! }

    @MainActor
    func testCreatedAnswersTheCreate() {
        let plugin = HerdrPlugin()
        plugin.model.actions["d"] = HerdrAction(action: "create", seq: 3, what: "agent")
        plugin.receive(packet(#"{"kind":"closed","pane":"w4:p1"}"#), deviceId: "d", computer: "c")
        XCTAssertEqual(plugin.model.actions["d"]?.sending, true, "a closed answer does not answer a create")
        plugin.receive(packet(#"{"kind":"created","what":"agent","pane":"w4:p1"}"#), deviceId: "d", computer: "c")
        XCTAssertEqual(plugin.model.actions["d"], HerdrAction(action: "create", seq: 3, sending: false, pane: "w4:p1", what: "agent"))
        plugin.receive(packet(#"{"kind":"created","what":"agent","error":"late"}"#), deviceId: "d", computer: "c")
        XCTAssertNil(plugin.model.actions["d"]?.error, "a second answer changes nothing")
        plugin.clearAction("d", seq: 2)
        XCTAssertNotNil(plugin.model.actions["d"], "only the answered action clears")
        plugin.clearAction("d", seq: 3)
        XCTAssertNil(plugin.model.actions["d"])
    }

    @MainActor
    func testCreatedWithAnError() {
        let plugin = HerdrPlugin()
        plugin.model.actions["d"] = HerdrAction(action: "create", seq: 1, what: "terminal")
        plugin.receive(packet(#"{"kind":"created","what":"terminal","error":"Terminals are off"}"#), deviceId: "d", computer: "c")
        XCTAssertEqual(plugin.model.actions["d"]?.error, "Terminals are off")
        XCTAssertNil(plugin.model.actions["d"]?.pane)
        XCTAssertEqual(plugin.model.actions["d"]?.sending, false)
    }

    @MainActor
    func testClosedAnswersTheCloseOfItsPane() {
        let plugin = HerdrPlugin()
        plugin.model.actions["d"] = HerdrAction(action: "close", seq: 1, pane: "w4:p1")
        plugin.receive(packet(#"{"kind":"closed","pane":"w9:p1"}"#), deviceId: "d", computer: "c")
        XCTAssertEqual(plugin.model.actions["d"]?.sending, true, "the close of another pane is no answer")
        plugin.receive(packet(#"{"kind":"closed","pane":"w4:p1"}"#), deviceId: "d", computer: "c")
        XCTAssertEqual(plugin.model.actions["d"], HerdrAction(action: "close", seq: 1, sending: false, pane: "w4:p1"))
    }

    @MainActor
    func testActionsWithoutALinkFail() {
        let plugin = HerdrPlugin()
        plugin.create("d", what: "agent", kind: "claude", cwd: "~", workspace: "")
        XCTAssertEqual(plugin.model.actions["d"]?.action, "create")
        XCTAssertEqual(plugin.model.actions["d"]?.what, "agent")
        XCTAssertEqual(plugin.model.actions["d"]?.sending, false)
        XCTAssertEqual(plugin.model.actions["d"]?.error, "The computer is not reachable")
        plugin.close("d", pane: "w1:p1")
        XCTAssertEqual(plugin.model.actions["d"]?.pane, "w1:p1")
        XCTAssertGreaterThan(plugin.model.actions["d"]?.seq ?? 0, 1, "each action has a new number")
    }

    @MainActor
    func testInputChecksItsKeysAndLength() {
        let plugin = HerdrPlugin()
        plugin.sendInput("d", pane: "w1:p2", text: "", keys: [])
        XCTAssertNil(plugin.model.replies["d"], "an empty input sends nothing")
        plugin.sendInput("d", pane: "w1:p2", text: "", keys: ["f1"])
        XCTAssertNil(plugin.model.replies["d"], "a key that fluxd refuses sends nothing")
        plugin.sendInput("d", pane: "w1:p2", text: String(repeating: "x", count: HerdrWire.maxPrompt + 1), keys: ["enter"])
        XCTAssertEqual(plugin.model.replies["d"]?.error, "The text is too long. The limit is 16 KB.")
        XCTAssertEqual(plugin.model.replies["d"]?.action, "input")
        plugin.sendInput("d", pane: "w1:p2", text: "ls", keys: ["enter"])
        XCTAssertEqual(plugin.model.replies["d"]?.error, "The computer is not reachable")
    }
}
