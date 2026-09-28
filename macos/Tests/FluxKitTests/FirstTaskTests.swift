import XCTest
@testable import FluxKit

/// The first task of a new agent: it goes as a prompt when the agent is
/// ready, and after the answer to a question such as the trust dialog.
final class FirstTaskTests: XCTestCase {
    func testSendsWhenTheNewAgentIsIdle() {
        var t = FirstTask(text: "Reply with ok")
        XCTAssertEqual(t.phase, .starting)
        XCTAssertFalse(t.update(status: .idle, choices: false), "nothing goes before the computer names the pane")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertEqual(t.phase, .waiting)
        XCTAssertEqual(t.pane, "w4:p1")
        XCTAssertFalse(t.update(status: nil, choices: false), "a pane that is not in the list yet waits")
        XCTAssertFalse(t.update(status: .working, choices: false))
        XCTAssertFalse(t.update(status: .unknown, choices: false))
        XCTAssertEqual(t.phase, .waiting)
        XCTAssertTrue(t.update(status: .idle, choices: false))
        XCTAssertEqual(t.phase, .sending)
        XCTAssertFalse(t.update(status: .idle, choices: false), "the task goes once")
        t.sent(error: nil)
        XCTAssertEqual(t.phase, .sent)
        XCTAssertFalse(t.update(status: .idle, choices: false))
    }

    func testDoneIsReadyToo() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertTrue(t.update(status: .done, choices: false))
    }

    func testWaitsForTheAnswerToTheTrustDialog() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertFalse(t.update(status: .blocked, choices: true))
        XCTAssertEqual(t.phase, .answering)
        XCTAssertFalse(t.update(status: .blocked, choices: false), "blocked without choices still waits for an answer")
        XCTAssertFalse(t.update(status: .working, choices: false))
        XCTAssertEqual(t.phase, .answering, "the phase stays until the agent is ready")
        XCTAssertTrue(t.update(status: .idle, choices: false))
        XCTAssertEqual(t.phase, .sending)
    }

    func testChoicesOnScreenHoldTheTask() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertFalse(t.update(status: .idle, choices: true), "a dialog on screen needs an answer, whatever the status")
        XCTAssertEqual(t.phase, .answering)
        XCTAssertTrue(t.update(status: .idle, choices: false), "new output without the dialog lets the task go")
    }

    func testAFailedCreateFails() {
        var t = FirstTask(text: "go")
        t.created(pane: nil, error: "claude did not start")
        XCTAssertEqual(t.phase, .failed("claude did not start"))
        XCTAssertFalse(t.update(status: .idle, choices: false))
        XCTAssertTrue(t.finished)
    }

    func testAnAgentThatStopsFails() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertFalse(t.update(status: .working, choices: false))
        XCTAssertFalse(t.update(status: nil, choices: false))
        XCTAssertEqual(t.phase, .failed("The agent stopped before it got the task."))
    }

    func testAFailedPromptFails() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertTrue(t.update(status: .idle, choices: false))
        t.sent(error: "roger did not answer")
        XCTAssertEqual(t.phase, .failed("roger did not answer"))
        XCTAssertTrue(t.finished)
    }

    func testTheTextIsTrimmed() {
        XCTAssertEqual(FirstTask(text: "  go on \n").text, "go on")
    }

    // MARK: Plugin

    private func packet(_ json: String) -> Packet { Packet.parse(#"{"id":1,"type":"flux.herdr","body":\#(json)}"#)! }

    private func state(_ status: String) -> Packet {
        packet(#"{"kind":"state","enabled":true,"running":true,"control":true,"agents":[{"pane":"w4:p1","agent":"claude","status":"\#(status)"}]}"#)
    }

    @MainActor
    func testThePluginSendsTheTaskOfItsCreate() {
        let plugin = HerdrPlugin()
        plugin.create("d", what: "agent", kind: "claude", cwd: "~", workspace: "", task: "Reply with ok")
        XCTAssertEqual(plugin.model.firstTasks["d"]?.phase, .failed("The computer is not reachable"),
                       "a create that cannot go takes its task with it")

        plugin.model.actions["d"] = HerdrAction(action: "create", seq: 7, what: "agent")
        plugin.model.firstTasks["d"] = FirstTask(text: "Reply with ok", action: 7)
        plugin.receive(state("blocked"), deviceId: "d", computer: "c")
        XCTAssertEqual(plugin.model.firstTasks["d"]?.phase, .starting)
        plugin.receive(packet(#"{"kind":"created","what":"agent","pane":"w4:p1"}"#), deviceId: "d", computer: "c")
        XCTAssertEqual(plugin.model.firstTasks["d"]?.phase, .answering, "the state before the created answer counts")
        XCTAssertNil(plugin.model.replies["d"])
        plugin.receive(state("idle"), deviceId: "d", computer: "c")
        // The plugin has no link here, so the prompt fails at once.
        XCTAssertEqual(plugin.model.replies["d"]?.action, "prompt")
        XCTAssertEqual(plugin.model.replies["d"]?.pane, "w4:p1")
        XCTAssertEqual(plugin.model.firstTasks["d"]?.phase, .failed("The computer is not reachable"))
        plugin.clearFirstTask("d")
        XCTAssertNil(plugin.model.firstTasks["d"])
    }

    @MainActor
    func testTheSentAnswerEndsTheTask() {
        let plugin = HerdrPlugin()
        var t = FirstTask(text: "go", action: 1)
        t.created(pane: "w4:p1", error: nil)
        XCTAssertTrue(t.update(status: .idle, choices: false))
        plugin.model.firstTasks["d"] = t
        plugin.receive(packet(#"{"kind":"sent","pane":"w4:p1","action":"keys"}"#), deviceId: "d", computer: "c")
        XCTAssertEqual(plugin.model.firstTasks["d"]?.phase, .sending, "keys do not answer the task")
        plugin.receive(packet(#"{"kind":"sent","pane":"w4:p1","action":"prompt"}"#), deviceId: "d", computer: "c")
        XCTAssertEqual(plugin.model.firstTasks["d"]?.phase, .sent)
    }

    @MainActor
    func testAnotherCreateIgnoresTheTask() {
        let plugin = HerdrPlugin()
        plugin.model.actions["d"] = HerdrAction(action: "create", seq: 9, what: "agent")
        plugin.model.firstTasks["d"] = FirstTask(text: "go", action: 8)
        plugin.receive(packet(#"{"kind":"created","what":"agent","pane":"w4:p1"}"#), deviceId: "d", computer: "c")
        XCTAssertEqual(plugin.model.firstTasks["d"]?.phase, .starting, "the task waits for its own create")
    }

    @MainActor
    func testATerminalHasNoTask() {
        let plugin = HerdrPlugin()
        plugin.create("d", what: "terminal", kind: "", cwd: "~", workspace: "", task: "ls")
        XCTAssertNil(plugin.model.firstTasks["d"])
    }
}
