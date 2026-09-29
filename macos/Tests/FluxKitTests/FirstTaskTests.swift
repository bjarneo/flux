import XCTest
@testable import FluxKit

/// The first task of a new agent: it goes as a prompt when the agent is
/// ready, and after the answer to a question such as the trust dialog.
final class FirstTaskTests: XCTestCase {
    private var now: TimeInterval = 100

    /// Updates at the current time.
    private func update(_ t: inout FirstTask, _ status: AgentStatus?, choices: Bool = false) -> Bool {
        t.update(status: status, choices: choices, now: now)
    }

    /// Lets the agent stay ready for the hold: the first ready update starts
    /// it, and the update at its end sends the task.
    private func readyForTheHold(_ t: inout FirstTask, _ status: AgentStatus = .idle) -> Bool {
        let started = update(&t, status)
        now += FirstTask.hold
        return !started && update(&t, status)
    }

    func testSendsWhenTheNewAgentStaysIdle() {
        var t = FirstTask(text: "Reply with ok")
        XCTAssertEqual(t.phase, .starting)
        XCTAssertFalse(update(&t, .idle), "nothing goes before the computer names the pane")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertEqual(t.phase, .waiting)
        XCTAssertEqual(t.pane, "w4:p1")
        XCTAssertFalse(update(&t, nil), "a pane that is not in the list yet waits")
        XCTAssertFalse(update(&t, .working))
        XCTAssertFalse(update(&t, .unknown))
        XCTAssertEqual(t.phase, .waiting)
        XCTAssertFalse(update(&t, .idle), "the first ready state starts the hold")
        XCTAssertEqual(t.due, now + FirstTask.hold)
        now += FirstTask.hold - 0.1
        XCTAssertFalse(update(&t, .idle), "the task waits for the whole hold")
        now += 0.1
        XCTAssertTrue(update(&t, .idle))
        XCTAssertEqual(t.phase, .sending)
        XCTAssertFalse(update(&t, .idle), "the task goes once")
        t.sent(error: nil)
        XCTAssertEqual(t.phase, .sent)
        XCTAssertFalse(update(&t, .idle))
    }

    func testDoneIsReadyToo() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertTrue(readyForTheHold(&t, .done))
    }

    func testWaitsForTheAnswerToTheTrustDialog() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertFalse(update(&t, .blocked, choices: true))
        XCTAssertEqual(t.phase, .answering)
        XCTAssertFalse(update(&t, .blocked), "blocked without choices still waits for an answer")
        XCTAssertFalse(update(&t, .working))
        XCTAssertEqual(t.phase, .answering, "the phase stays until the agent is ready")
        XCTAssertTrue(readyForTheHold(&t))
        XCTAssertEqual(t.phase, .sending)
    }

    func testANewDialogDuringTheHoldStopsIt() {
        // Claude Code shows the next dialog right after the trust dialog.
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertFalse(update(&t, .blocked))
        XCTAssertFalse(update(&t, .idle))
        now += 0.5
        XCTAssertFalse(update(&t, .blocked), "the next dialog")
        XCTAssertNil(t.due)
        XCTAssertEqual(t.phase, .answering)
        now += FirstTask.hold
        XCTAssertFalse(update(&t, .idle), "the hold starts again after the answer")
        now += FirstTask.hold
        XCTAssertTrue(update(&t, .idle))
    }

    func testWorkingDuringTheHoldStopsIt() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertFalse(update(&t, .idle))
        XCTAssertFalse(update(&t, .working))
        XCTAssertNil(t.due)
        now += FirstTask.hold
        XCTAssertFalse(update(&t, .idle))
    }

    func testChoicesOnScreenHoldTheTask() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertFalse(update(&t, .idle))
        now += FirstTask.hold
        XCTAssertFalse(update(&t, .idle, choices: true), "a dialog on screen needs an answer, whatever the status")
        XCTAssertEqual(t.phase, .answering)
        XCTAssertTrue(readyForTheHold(&t), "new output without the dialog lets the task go after the hold")
    }

    func testAFailedCreateFails() {
        var t = FirstTask(text: "go")
        t.created(pane: nil, error: "claude did not start")
        XCTAssertEqual(t.phase, .failed("claude did not start"))
        XCTAssertFalse(update(&t, .idle))
        XCTAssertTrue(t.finished)
    }

    func testAnAgentThatStopsFails() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertFalse(update(&t, .working))
        XCTAssertFalse(update(&t, nil))
        XCTAssertEqual(t.phase, .failed("The agent stopped before it got the task."))
    }

    func testAnAgentThatNeverAppearsFails() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertFalse(update(&t, nil))
        XCTAssertEqual(t.appearDue, now + FirstTask.appearLimit)
        now += FirstTask.appearLimit - 1
        XCTAssertFalse(update(&t, nil))
        XCTAssertEqual(t.phase, .waiting, "the agent list can take a while")
        now += 1
        XCTAssertFalse(update(&t, nil))
        XCTAssertEqual(t.phase, .failed("The agent did not appear."))
        XCTAssertNil(t.appearDue)
    }

    func testAnAgentThatAppearsHasNoDeadline() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertFalse(update(&t, nil))
        XCTAssertFalse(update(&t, .working))
        XCTAssertNil(t.appearDue)
        now += FirstTask.appearLimit * 2
        XCTAssertFalse(update(&t, .working))
        XCTAssertEqual(t.phase, .waiting, "a working agent may take its time")
    }

    func testAFailedPromptFails() {
        var t = FirstTask(text: "go")
        t.created(pane: "w4:p1", error: nil)
        XCTAssertTrue(readyForTheHold(&t))
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
        var clock: TimeInterval = 50
        plugin.clock = { clock }
        plugin.receive(state("idle"), deviceId: "d", computer: "c")
        XCTAssertNil(plugin.model.replies["d"], "the task waits for the hold")
        clock += FirstTask.hold
        plugin.receive(state("idle"), deviceId: "d", computer: "c")
        // The plugin has no link here, so the prompt fails at once.
        XCTAssertEqual(plugin.model.replies["d"]?.action, "prompt")
        XCTAssertEqual(plugin.model.replies["d"]?.pane, "w4:p1")
        XCTAssertEqual(plugin.model.firstTasks["d"]?.phase, .failed("The computer is not reachable"))
        plugin.clearFirstTask("d")
        XCTAssertNil(plugin.model.firstTasks["d"])
    }

    @MainActor
    func testThePluginFailsATaskWhoseAgentNeverAppears() {
        let plugin = HerdrPlugin()
        var clock: TimeInterval = 50
        plugin.clock = { clock }
        plugin.model.actions["d"] = HerdrAction(action: "create", seq: 7, what: "agent")
        plugin.model.firstTasks["d"] = FirstTask(text: "go", action: 7)
        plugin.receive(packet(#"{"kind":"created","what":"agent","pane":"w9:p9"}"#), deviceId: "d", computer: "c")
        XCTAssertEqual(plugin.model.firstTasks["d"]?.phase, .waiting, "the deadline starts without any state")
        XCTAssertEqual(plugin.model.firstTasks["d"]?.appearDue, 50 + FirstTask.appearLimit)
        clock += FirstTask.appearLimit
        plugin.receive(state("idle"), deviceId: "d", computer: "c")
        XCTAssertEqual(plugin.model.firstTasks["d"]?.phase, .failed("The agent did not appear."))
    }

    @MainActor
    func testTheSentAnswerEndsTheTask() {
        let plugin = HerdrPlugin()
        var t = FirstTask(text: "go", action: 1)
        t.created(pane: "w4:p1", error: nil)
        XCTAssertTrue(readyForTheHold(&t))
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
