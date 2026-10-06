import XCTest
@testable import FluxKit

/// Ported from HerdrReplyTest.kt of the Android app, plus the state tracker.
final class HerdrTests: XCTestCase {
    private func body(_ json: String) -> [String: JSONValue] {
        Packet.parse(#"{"id":1,"type":"flux.herdr","body":\#(json)}"#)!.body
    }

    private let esc = "\u{1B}"

    func testParsesBasicColors() {
        let lines = TermText.parse("\(esc)[1;31mred bold\(esc)[0m plain \(esc)[42m bg \(esc)[0m")
        XCTAssertEqual(lines.count, 1)
        let spans = lines[0].spans
        XCTAssertEqual(spans[0], TermSpan("red bold", TermStyle(fg: .indexed(1), bold: true)))
        XCTAssertEqual(spans[1], TermSpan(" plain ", TermStyle()))
        XCTAssertEqual(spans[2], TermSpan(" bg ", TermStyle(bg: .indexed(2))))
    }

    func testParsesHerdrColorForms() {
        // herdr sends the basic colors as palette entries.
        let lines = TermText.parse("\(esc)[0m\(esc)[1m\(esc)[38;5;6m/tmp\(esc)[0m \(esc)[38;2;215;119;87mtrue\(esc)[0m \(esc)[48;5;2mbg\(esc)[39;49m")
        XCTAssertEqual(lines.count, 1)
        let spans = lines[0].spans
        XCTAssertEqual(spans[0], TermSpan("/tmp", TermStyle(fg: .indexed(6), bold: true)))
        XCTAssertEqual(spans[2], TermSpan("true", TermStyle(fg: .rgb(0xD77757))))
        XCTAssertEqual(spans[4], TermSpan("bg", TermStyle(bg: .indexed(2))))
    }

    func testParsesBrightAndColonForms() {
        let s = TermText.applySgr(TermStyle(), "93;104")
        XCTAssertEqual(s.fg, .indexed(11))
        XCTAssertEqual(s.bg, .indexed(12))
        XCTAssertEqual(TermText.applySgr(TermStyle(), "38:2::10:20:30").fg, .rgb(0x0A141E))
        XCTAssertEqual(TermText.applySgr(TermStyle(), "48:5:200").bg, .indexed(200))
        XCTAssertTrue(TermText.applySgr(TermStyle(), "4:3").underline)
        XCTAssertFalse(TermText.applySgr(TermStyle(underline: true), "4:0").underline)
    }

    func testResetsStyles() {
        var s = TermText.applySgr(TermStyle(), "1;2;3;4;7;9;31;42")
        XCTAssertEqual(s, TermStyle(fg: .indexed(1), bg: .indexed(2), bold: true, dim: true, italic: true, underline: true, inverse: true, strike: true))
        s = TermText.applySgr(s, "22;23;24;27;29;39;49")
        XCTAssertEqual(s, TermStyle())
        XCTAssertEqual(TermText.applySgr(TermStyle(bold: true), ""), TermStyle(), "an empty parameter list resets")
        XCTAssertEqual(TermText.applySgr(TermStyle(fg: .indexed(3)), "0"), TermStyle())
    }

    func testIgnoresBadColors() {
        XCTAssertNil(TermText.applySgr(TermStyle(), "38;5;300").fg, "an index above 255 is not a color")
        XCTAssertNil(TermText.applySgr(TermStyle(), "38;2;1;2").fg, "an incomplete color is not a color")
        // An unknown color form ends the parameters, so 9 and 1 do not become styles.
        XCTAssertEqual(TermText.applySgr(TermStyle(), "1;38;9;1"), TermStyle(bold: true))
        XCTAssertEqual(TermText.applySgr(TermStyle(), ">4"), TermStyle(), "a private form changes nothing")
    }

    func testDropsOtherSequencesAndControls() {
        let text = "a\(esc)[2Kb\(esc)]8;;https://example.com\(esc)\\link\(esc)]8;;\u{07}c\(esc)(Bd\(esc)7e\r\u{01}f"
        XCTAssertEqual(TermText.parse(text).map(\.text), ["ablinkcdef"])
        XCTAssertEqual(TermText.parse("x\(esc)").map(\.text), ["x"], "a lone escape at the end goes")
    }

    func testDropsC1AndMarksBidiControls() {
        let text = "ok \u{202E}exe.sh\u{202C} \u{85}done\u{9B}\u{2066}x\u{2069}\u{2028}"
        XCTAssertEqual(TermText.parse(text).map(\.text), ["ok \u{FFFD}exe.sh\u{FFFD} done\u{FFFD}x\u{FFFD}\u{FFFD}"])
    }

    func testExpandsTabsAndSplitsLines() {
        let lines = TermText.parse("a\tb\r\n\tc\n")
        XCTAssertEqual(lines.map(\.text), ["a       b", "        c"])
        XCTAssertEqual(TermText.parse("❯\u{A0}x").map(\.text), ["❯ x"], "a no-break space becomes a space")
    }

    func testStylesContinueOnTheNextLine() {
        let lines = TermText.parse("\(esc)[32mone\ntwo\(esc)[0m")
        XCTAssertEqual(lines[1].spans.map(\.style), [TermStyle(fg: .indexed(2))])
    }

    func testTidiesStyledLines() {
        let rule = "\(esc)[38;5;4m" + String(repeating: "─", count: 80) + "\(esc)[0m"
        let lines = TermText.lines("\(rule)\n\(esc)[1mbold\(esc)[0m   \(esc)[41m   \(esc)[0m\n\n  \n")
        XCTAssertEqual(lines.count, 2)
        let fitted = TermText.fit(lines, cols: 32)
        XCTAssertEqual(fitted[0].text, String(repeating: "─", count: 32))
        XCTAssertEqual(fitted[0].spans.map(\.style.fg), [.indexed(4)], "a shortened rule keeps its color")
        XCTAssertEqual(lines[1].spans, [TermSpan("bold", TermStyle(bold: true))], "trailing blanks go, also with a background")
    }

    func testComputesThePalette() {
        XCTAssertNil(TermText.paletteRgb(15))
        XCTAssertEqual(TermText.paletteRgb(16), 0x000000)
        XCTAssertEqual(TermText.paletteRgb(231), 0xFFFFFF)
        XCTAssertEqual(TermText.paletteRgb(173), 0xD7875F)
        XCTAssertEqual(TermText.paletteRgb(232), 0x080808)
        XCTAssertEqual(TermText.paletteRgb(255), 0xEEEEEE)
    }

    private let claudeDialog = [
        "● I will run the migration.",
        "Steps:",
        "1. Check the schema",
        "2. Apply the change",
        String(repeating: "─", count: 32),
        " Bash command",
        "",
        "   bin/migrate --apply",
        "",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and don't ask again for bin/migrate commands",
        "   3. No, and tell Claude what to do differently (esc)",
    ]

    func testFindsTheChoicesOfADialog() {
        XCTAssertEqual(AgentChoice.find(claudeDialog), [
            AgentChoice("1", "Yes", selected: true),
            AgentChoice("2", "Yes, and don't ask again for bin/migrate commands"),
            AgentChoice("3", "No, and tell Claude what to do differently (esc)"),
        ])
    }

    func testFindsChoicesWithDescriptionsAndARule() {
        let lines = [
            "Which database do you want?",
            "❯ 1. Postgres",
            "     The default for new services",
            "  2. SQLite",
            "     A file on the disk",
            "  3. Type something.",
            String(repeating: "─", count: 32),
            "  4. Chat about this",
            "",
            "Enter to select · ↑/↓ to navigate · Esc to cancel",
        ]
        XCTAssertEqual(AgentChoice.find(lines).map(\.key), ["1", "2", "3", "4"])
    }

    func testFindsNoChoicesInProse() {
        XCTAssertTrue(AgentChoice.find(["1. Only one"]).isEmpty, "a single choice is not a dialog")
        let prose = ["1. Check the schema", "2. Apply the change"] + (0..<20).map { "more output \($0)" }
        XCTAssertTrue(AgentChoice.find(prose).isEmpty, "a list far from the end is not a dialog")
        XCTAssertTrue(AgentChoice.find([]).isEmpty)
        XCTAssertTrue(AgentChoice.find(["1.x", "2)y"]).isEmpty, "a choice needs a blank after its number")
        XCTAssertEqual(AgentChoice.find(["1) a", "2) b", "123. c"]).map(\.key), ["1", "2"])
    }

    func testOutputKeepsColorsAndFindsChoices() throws {
        let text = claudeDialog.joined(separator: "\n").replacingOccurrences(of: " ❯ 1. Yes", with: " \(esc)[38;5;4m❯ 1. Yes\(esc)[0m")
        let json = String(decoding: JSONValue.string(text).serialized(), as: UTF8.self)
        let o = try XCTUnwrap(HerdrWire.output(body(#"{"kind":"output","pane":"w5:p1","format":"ansi","text":\#(json)}"#)))
        XCTAssertEqual(o.text, claudeDialog.joined(separator: "\n"))
        XCTAssertEqual(o.lines[10].spans.last?.style.fg, .indexed(4))
        XCTAssertEqual(o.choices.count, 3)
        XCTAssertFalse(o.loading)
    }

    func testOutputWithAnError() throws {
        let o = try XCTUnwrap(HerdrWire.output(body(#"{"kind":"output","pane":"w5:p1","error":"The agent in w5:p1 is gone","text":"x"}"#)))
        XCTAssertEqual(o.error, "The agent in w5:p1 is gone")
        XCTAssertTrue(o.lines.isEmpty)
        XCTAssertNil(HerdrWire.output(body(#"{"kind":"output","text":"x"}"#)), "an output needs a pane")
    }

    func testParsesState() throws {
        let s = try XCTUnwrap(HerdrWire.state(body(#"""
        {"kind":"state","enabled":true,"running":true,"control":false,"agents":[
          {"pane":"w1:p1","agent":"codex","status":"idle","title":"","project":"flux","workspace":"flux"},
          {"pane":"w5:p1","agent":"claude","status":"blocked","title":"Custom skin loading","project":"cliamp","workspace":"cliamp"},
          {"pane":"w6:p2","agent":"","status":"thinking"},
          {"pane":"w7:p1","agent":"pi","status":"working"},
          {"pane":"","agent":"lost","status":"done"},
          {"pane":"w8:p1","agent":"amp","status":"done"}]}
        """#)))
        XCTAssertTrue(s.enabled)
        XCTAssertTrue(s.running)
        XCTAssertEqual(s.agents.count, 5, "an agent needs a pane")
        XCTAssertEqual(s.agent("w6:p2")?.agent, "agent", "an agent with no name gets a name")
        XCTAssertEqual(s.agent("w6:p2")?.status, .unknown)
        XCTAssertEqual(s.blocked, 1)
        XCTAssertEqual(s.sorted.map(\.pane), ["w5:p1", "w8:p1", "w7:p1", "w1:p1", "w6:p2"], "blocked, done, working, idle, then unknown")
        XCTAssertEqual(s.agent("w5:p1"), HerdrAgent(pane: "w5:p1", agent: "claude", status: .blocked, title: "Custom skin loading", project: "cliamp", workspace: "cliamp"))
    }

    func testSortKeepsTheHerdrOrderInAGroup() {
        let agents = ["a", "b", "c", "d"].map { HerdrAgent(pane: $0, agent: "claude", status: $0 == "c" ? .blocked : .working) }
        XCTAssertEqual(HerdrState(enabled: true, running: true, agents: agents).sorted.map(\.pane), ["c", "a", "b", "d"])
    }

    func testParsesControl() throws {
        let on = try XCTUnwrap(HerdrWire.state(body(#"{"kind":"state","enabled":true,"running":true,"control":true,"agents":[]}"#)))
        XCTAssertTrue(on.control)
        let missing = try XCTUnwrap(HerdrWire.state(body(#"{"kind":"state","enabled":true,"running":true,"agents":[]}"#)))
        XCTAssertFalse(missing.control, "a missing control field is false")
        let off = try XCTUnwrap(HerdrWire.state(body(#"{"kind":"state","enabled":false,"control":true,"running":true}"#)))
        XCTAssertFalse(off.control, "a computer with herdr off takes no replies")
        XCTAssertFalse(off.running)
        XCTAssertNil(HerdrWire.state(body(#"{"kind":"output","pane":"w5:p1"}"#)))
    }

    func testParsesSent() throws {
        XCTAssertEqual(HerdrWire.sent(body(#"{"kind":"sent","pane":"w5:p1","action":"keys"}"#)), HerdrSent(pane: "w5:p1", action: "keys", error: nil))
        let e = try XCTUnwrap(HerdrWire.sent(body(#"{"kind":"sent","pane":"w5:p1","action":"prompt","error":"Replies from the phone are off on this computer."}"#)))
        XCTAssertEqual(e.action, "prompt")
        XCTAssertEqual(e.error, "Replies from the phone are off on this computer.")
        XCTAssertNil(HerdrWire.sent(body(#"{"kind":"sent","action":"keys"}"#)), "a sent answer needs a pane")
        let blocked = try XCTUnwrap(HerdrWire.sent(body(#"{"kind":"sent","pane":"w5:p1","action":"prompt","error":"Pick a choice first.","code":"blocked","request":7}"#)))
        XCTAssertEqual(blocked.code, HerdrWire.blockedCode)
        XCTAssertEqual(blocked.request, 7)
        XCTAssertNil(e.code)
        XCTAssertNil(e.request, "an older fluxd sends no number")
        XCTAssertNil(HerdrWire.sent(body(#"{"kind":"output","pane":"w5:p1"}"#)), "an output is not a sent answer")
    }

    func testKeysMatchTheComputer() {
        for k in ["enter", "esc", "tab", "shift+tab", "up", "down", "left", "right", "backspace", "space", "y", "n", "0", "9"] {
            XCTAssertTrue(HerdrWire.allowedKeys.contains(k), k)
        }
        XCTAssertFalse(HerdrWire.allowedKeys.contains("ctrl+c"))
        XCTAssertEqual(HerdrWire.allowedKeys.count, 22)
        XCTAssertTrue(HerdrWire.allowed(["shift+tab"]))
        XCTAssertFalse(HerdrWire.allowed([]))
        XCTAssertFalse(HerdrWire.allowed(Array(repeating: "up", count: 9)), "fluxd takes at most 8 keys")
        XCTAssertFalse(HerdrWire.allowed(["enter", "ctrl+c"]))
    }

    func testPacketsMatchTheComputer() {
        let read = HerdrWire.read(pane: "w5:p1")
        XCTAssertEqual(read.type, "flux.herdr")
        XCTAssertEqual(read.body, ["kind": .string("read"), "pane": .string("w5:p1"), "lines": .int(1000), "format": .string("ansi")])
        XCTAssertEqual(HerdrWire.keys(pane: "w5:p1", ["2"]).body, ["kind": .string("keys"), "pane": .string("w5:p1"), "keys": .array([.string("2")])])
        XCTAssertEqual(HerdrWire.prompt(pane: "w5:p1", "go on").body, ["kind": .string("prompt"), "pane": .string("w5:p1"), "text": .string("go on")])
        // fluxd types into the dialog of an agent that waits for a choice
        // only with "answer".
        XCTAssertEqual(HerdrWire.prompt(pane: "w5:p1", "3", answer: true).body,
                       ["kind": .string("prompt"), "pane": .string("w5:p1"), "text": .string("3"), "answer": .bool(true)])
        XCTAssertEqual(HerdrWire.request().body, ["kind": .string("request")])
        XCTAssertTrue(PacketType.fluxHerdr == "flux.herdr")
    }

    func testOutputKeepsTheEndOfALongText() {
        XCTAssertEqual(HerdrWire.tail("short", max: 10).0, "short")
        XCTAssertFalse(HerdrWire.tail("short", max: 10).1)
        let (end, cut) = HerdrWire.tail("line 1\nline 2\nline 3", max: 10)
        XCTAssertTrue(cut)
        XCTAssertEqual(end, "line 3", "the end starts at a line")
        let (chars, _) = HerdrWire.tail(String(repeating: "é", count: 20), max: 9)
        XCTAssertEqual(chars, "éééé", "the end starts at a whole character")

        let text = String(repeating: "x", count: HerdrWire.maxText + 10)
        let body: [String: JSONValue] = ["kind": .string("output"), "pane": .string("w5:p1"), "text": .string(text)]
        let o = HerdrWire.output(body)
        XCTAssertEqual(o?.truncated, true)
        XCTAssertLessThanOrEqual(o?.text.utf8.count ?? .max, HerdrWire.maxText)
    }

    // MARK: Tracker

    private func agent(_ pane: String, _ status: AgentStatus) -> HerdrAgent { HerdrAgent(pane: pane, agent: "claude", status: status, project: "flux") }

    func testFirstListPostsNothing() {
        var t = HerdrTracker()
        XCTAssertEqual(t.update([agent("p1", .blocked), agent("p2", .done), agent("p3", .working)]), [.clear("p3")],
                       "the first list only clears the notification of a working agent")
        XCTAssertEqual(t.update([agent("p1", .blocked), agent("p2", .done), agent("p3", .working)]), [])
    }

    func testFindsTheChanges() {
        var t = HerdrTracker()
        _ = t.update([agent("p1", .working), agent("p2", .idle)])
        XCTAssertEqual(t.update([agent("p1", .blocked), agent("p2", .idle)]), [.needsInput(agent("p1", .blocked))])
        XCTAssertEqual(t.update([agent("p1", .working), agent("p2", .idle)]), [.clear("p1")], "working again removes the notification")
        XCTAssertEqual(t.update([agent("p1", .done), agent("p2", .idle)]), [.finished(agent("p1", .done))])
        XCTAssertEqual(t.update([agent("p1", .idle), agent("p2", .idle)]), [.clear("p1")], "done to idle is no new finish")
    }

    func testUnknownKeepsTheLastStatus() {
        var t = HerdrTracker()
        _ = t.update([agent("p1", .working)])
        XCTAssertEqual(t.update([agent("p1", .unknown)]), [])
        XCTAssertEqual(t.update([agent("p1", .done)]), [.finished(agent("p1", .done))])
    }

    func testNewAndGoneAgents() {
        var t = HerdrTracker()
        _ = t.update([agent("p1", .working)])
        XCTAssertEqual(t.update([agent("p1", .working), agent("p2", .blocked)]), [], "a new agent that is already blocked posts nothing")
        XCTAssertEqual(t.update([agent("p2", .blocked)]), [.clear("p1")])
        XCTAssertEqual(t.update([]), [.clear("p2")])
    }

    func testRestartSetsTheStartValuesAgain() {
        var t = HerdrTracker()
        _ = t.update([agent("p1", .working)])
        t.restart()
        XCTAssertEqual(t.update([agent("p1", .blocked)]), [], "the first list after a reconnect posts nothing")
        XCTAssertEqual(t.update([agent("p1", .working)]), [.clear("p1")])
    }
}
