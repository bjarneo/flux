import XCTest
@testable import FluxKit

/// Ported from InboxModelTest.kt of the Android app, plus the text of the items.
final class InboxModelTests: XCTestCase {
    private func device(_ id: String, paired: Bool = true, online: Bool = true, pairState: PairState? = nil) -> DeviceSnapshot {
        let state: PairState = pairState ?? (paired ? PairState.paired : PairState.none)
        return DeviceSnapshot(id: id, name: "name-\(id)", type: "laptop", ip: "", isFlux: true, paired: paired, online: online,
                              pairState: state, pairKey: "", incoming: [], outgoing: [])
    }

    private func agents(_ list: [HerdrAgent]) -> HerdrState {
        HerdrState(enabled: true, running: true, agents: list, control: true)
    }

    private func approval(_ computer: String) -> ApproveRequest {
        ApproveRequest(computerId: computer, computerName: "name-\(computer)", id: "r1", kind: .approve, host: "host",
                       user: "user", service: "sudo", tty: "pts/1", rhost: "", time: 0,
                       nonce: String(repeating: "0", count: 64), timeoutSeconds: 60)
    }

    private func inbox(_ devices: [DeviceSnapshot], herdr: [String: HerdrState] = [:], approval: ApproveRequest? = nil) -> [InboxItem] {
        Inbox.items(devices: devices, herdr: herdr, approval: approval)
    }

    private func agentOf(_ item: InboxItem) -> HerdrAgent? {
        if case .agent(_, let agent, _) = item.content { return agent }
        return nil
    }

    private let working = HerdrAgent(pane: "w1:p1", agent: "claude", status: .working, title: "Refactor")
    private let blocked = HerdrAgent(pane: "w2:p1", agent: "codex", status: .blocked, title: "Migrate")
    private let done = HerdrAgent(pane: "w3:p1", agent: "claude", status: .done, title: "Fix test")
    private let idle = HerdrAgent(pane: "w3:p2", agent: "pi", status: .idle)

    func testTheItemsAreTheAgentsTheApprovalAndThePairRequests() {
        let devices = [device("a"), device("new", paired: false, pairState: .incoming)]
        let items = inbox(devices, herdr: ["a": agents([working, blocked, done, idle])], approval: approval("a"))
        XCTAssertEqual(items.map { $0.kind }, [.agentWorking, .agentInput, .agentDone, .pairRequest, .approval])
        XCTAssertEqual(items.compactMap { agentOf($0) }.filter { $0.status == .idle }.count, 0, "an idle agent is not news")
        XCTAssertEqual(Inbox.needsYou(items), 3)
    }

    func testAComputerThatIsNotReachableKeepsOnlyItsAgentsThatWait() {
        let d = device("a", online: false)
        let items = inbox([d], herdr: ["a": agents([working, blocked, done])])
        XCTAssertEqual(items.map { $0.kind }, [.agentInput], "a blocked agent still waits, the others add no news")
        XCTAssertEqual(Inbox.needsYou(items), 1, "the badge counts the blocked agent")
    }

    func testAnOnlineComputerKeepsAllItsAgents() {
        let items = inbox([device("a")], herdr: ["a": agents([working, blocked, done])])
        XCTAssertEqual(items.map { $0.kind }, [.agentWorking, .agentInput, .agentDone])
    }

    func testTwoAgentsOnOnePaneMakeOneItem() {
        var twin = blocked
        twin.agent = "claude"
        let items = inbox([device("a")], herdr: ["a": agents([blocked, twin, done])])
        XCTAssertEqual(Set(items.map { $0.key }).count, items.count)
        XCTAssertEqual(items.count, 2)
        XCTAssertEqual(items.first.flatMap { agentOf($0) }?.agent, "codex")
    }

    func testTheReachCountsThePairedComputersInScope() {
        let a = device("a")
        let off = device("off", online: false)
        let stranger = device("new", paired: false)
        XCTAssertEqual(Inbox.reach(scope: nil, devices: [a, off, stranger]), InboxReach(online: 1, offline: [off]))
        XCTAssertTrue(Inbox.reach(scope: "off", devices: [a, off]).noneOnline)
        XCTAssertFalse(Inbox.reach(scope: "a", devices: [a, off]).noneOnline)
        XCTAssertFalse(Inbox.reach(scope: nil, devices: [stranger]).noneOnline, "no paired computer is not the same as none online")
    }

    func testTheScopeKeepsItsComputerAndThePairRequests() {
        let devices = [device("a"), device("b"), device("new", paired: false, pairState: .incoming)]
        let items = inbox(devices, herdr: ["a": agents([blocked]), "b": agents([done])])
        XCTAssertEqual(Inbox.inScope(items, scope: nil).count, 3)
        XCTAssertEqual(Inbox.inScope(items, scope: "b").map { $0.kind }, [.agentDone, .pairRequest])
    }

    func testAStatusChangeMakesANewItem() {
        var finished = blocked
        finished.status = .done
        let a = InboxItem(.agent(deviceId: "a", agent: blocked, control: true), computer: "a")
        let b = InboxItem(.agent(deviceId: "a", agent: finished, control: true), computer: "a")
        XCTAssertNotEqual(a.key, b.key)
    }

    func testTheTargetIsTheComputerInScopeOrTheOnlyOneOnline() {
        let a = device("a")
        let b = device("b")
        let off = device("off", online: false)
        let input: Set<String> = ["b"]
        XCTAssertEqual(Inbox.target(scope: "a", devices: [a, b]), ActionTarget.one(a))
        XCTAssertEqual(Inbox.target(scope: "off", devices: [a, off]), ActionTarget.unavailable(off))
        XCTAssertEqual(Inbox.target(scope: "gone", devices: [a]), ActionTarget.unavailable(nil))
        XCTAssertEqual(Inbox.target(scope: nil, devices: [a, b, off]), ActionTarget.ask([a, b]))
        XCTAssertEqual(Inbox.target(scope: nil, devices: [a, b], can: { input.contains($0.id) }), ActionTarget.one(b))
        XCTAssertEqual(Inbox.target(scope: "a", devices: [a, b], can: { input.contains($0.id) }), ActionTarget.unavailable(a))
        XCTAssertEqual(Inbox.target(scope: nil, devices: [off]), ActionTarget.unavailable(nil))
        XCTAssertEqual(Inbox.target(scope: nil, devices: [a, off]), ActionTarget.one(a))
        XCTAssertTrue(Inbox.hasFeature(scope: nil, devices: [a, b], can: { input.contains($0.id) }))
        XCTAssertFalse(Inbox.hasFeature(scope: "a", devices: [a, b], can: { input.contains($0.id) }))
    }

    private let dialog = [
        "● I added the migration.",
        String(repeating: "─", count: 40),
        " Bash command",
        "",
        "   bin/migrate --apply",
        "   Apply the pending migration",
        "",
        " Do you want to proceed?",
        " ❯ 1. Yes",
        "   2. Yes, and do not ask again",
        "   3. No",
    ]

    func testThePromptIsTheTextAboveTheChoices() {
        XCTAssertEqual(Inbox.agentPrompt(dialog),
                       "Bash command\nbin/migrate --apply\nApply the pending migration\nDo you want to proceed?")
        XCTAssertEqual(Inbox.agentPrompt(dialog, maxLines: 2), "Apply the pending migration\nDo you want to proceed?")
        // A short prompt drops the question, so that the command stays next to the choices.
        XCTAssertEqual(Inbox.agentPrompt(dialog, maxLines: 3, dropAsk: true),
                       "Bash command\nbin/migrate --apply\nApply the pending migration")
        XCTAssertEqual(Inbox.agentPrompt(dialog, maxLines: 2, dropAsk: true), "bin/migrate --apply\nApply the pending migration")
    }

    func testAShortPromptKeepsALastLineThatIsNotAQuestion() {
        let lines = ["Would you like to run the following command?", "", "$ bin/migrate --apply", "", "› 1. Yes, proceed (y)", "  2. No (esc)"]
        XCTAssertEqual(Inbox.agentPrompt(lines, maxLines: 3, dropAsk: true),
                       "Would you like to run the following command?\n$ bin/migrate --apply")
        // Without choices, nothing answers the question, so it stays.
        XCTAssertEqual(Inbox.agentPrompt(["Some work", "────", "", "Which file?", ""], maxLines: 3, dropAsk: true), "Which file?")
    }

    func testWithoutChoicesThePromptIsTheLastLines() {
        XCTAssertEqual(Inbox.agentPrompt(["Some work", "────", "", "Which file?", ""]), "Which file?")
        XCTAssertEqual(Inbox.agentPrompt([]), "")
    }

    func testAClipPreviewIsOneShortLine() {
        XCTAssertEqual(Inbox.clipPreview("  a\n\tb   c \n"), "a b c")
        XCTAssertEqual(Inbox.clipPreview("a\r\nb"), "a b")
        let long = Inbox.clipPreview(String(repeating: "x", count: 500), max: 10)
        XCTAssertEqual(long.count, 10)
        XCTAssertTrue(long.hasSuffix("…"))
        XCTAssertEqual(Inbox.clipPreview(String(repeating: "x", count: 160)).count, 160, "160 characters stay whole")
    }

    func testTheFeedNamesTheComputersOfAClip() throws {
        let c = try XCTUnwrap(ClipEvent.sent(to: [(id: "a", name: "desk"), (id: "b", name: "laptop")], text: "hello\nworld"))
        XCTAssertEqual(c.computer, "2 computers")
        XCTAssertEqual(c.preview, "hello world")
        XCTAssertEqual(c.deviceIds, ["a", "b"])
        XCTAssertTrue(c.sent)
        XCTAssertFalse(c.image)
        XCTAssertNil(ClipEvent.sent(to: [], text: "x"), "a clip that reached no computer is no event")
        let one = try XCTUnwrap(ClipEvent.sent(to: [(id: "a", name: "desk")], text: nil))
        XCTAssertEqual(one.computer, "desk")
        XCTAssertTrue(one.image)
        XCTAssertEqual(one.preview, "")
        let received = ClipEvent.received(from: "a", computer: "desk", text: nil)
        XCTAssertTrue(received.image)
        XCTAssertFalse(received.sent)
        XCTAssertEqual(received.computer, "desk")
        XCTAssertEqual(received.deviceIds, ["a"])
    }

    func testAClipOfASecretKeepsNoText() throws {
        let c = try XCTUnwrap(ClipEvent.sent(to: [(id: "a", name: "desk")], text: "s3cret\nvalue", secret: true))
        XCTAssertTrue(c.secret)
        XCTAssertFalse(c.image)
        XCTAssertEqual(c.preview, "Hidden text")
        XCTAssertFalse(c.preview.contains("s3cret"), "the event keeps no part of the secret")

        let direct = ClipEvent(deviceIds: ["a"], computer: "desk", sent: true, preview: "s3cret", secret: true)
        XCTAssertEqual(direct.preview, "Hidden text", "the init drops the text of a secret")

        let image = try XCTUnwrap(ClipEvent.sent(to: [(id: "a", name: "desk")], text: nil, secret: true))
        XCTAssertFalse(image.secret, "an image has no text to hide")
        XCTAssertTrue(image.image)
        let plain = try XCTUnwrap(ClipEvent.sent(to: [(id: "a", name: "desk")], text: "hello"))
        XCTAssertFalse(plain.secret)
        XCTAssertEqual(plain.preview, "hello")
    }

    // MARK: Text of the items

    func testItemTexts() {
        let noun = FluxPlatform.current.deviceNoun

        var waiting = blocked
        waiting.project = "billing"
        waiting.workspace = "ws"
        let input = InboxItem(.agent(deviceId: "a", agent: waiting, control: true), computer: "desk")
        XCTAssertEqual(input.kind, .agentInput)
        XCTAssertEqual(input.key, "agent|a|w2:p1|AgentInput")
        XCTAssertEqual(input.deviceIds, ["a"])
        XCTAssertEqual(input.stateWord, "Needs input")
        XCTAssertEqual(input.tone, .red)
        XCTAssertEqual(input.sourceParts, ["codex", "billing"])
        XCTAssertEqual(input.title, "Migrate")

        let finished = InboxItem(.agent(deviceId: "a", agent: done, control: true), computer: "desk")
        XCTAssertEqual(finished.stateWord, "Done")
        XCTAssertEqual(finished.tone, .green)
        XCTAssertEqual(finished.sourceParts, ["claude"], "a blank project and workspace are dropped")

        var bare = working
        bare.title = ""
        bare.workspace = "flux"
        let works = InboxItem(.agent(deviceId: "a", agent: bare, control: false), computer: "desk")
        XCTAssertEqual(works.stateWord, "Working")
        XCTAssertEqual(works.tone, .accent)
        XCTAssertEqual(works.sourceParts, ["claude", "flux"], "the workspace stands in for the project")
        XCTAssertEqual(works.title, "w1:p1", "without a title and a project, the pane names the agent")

        let approve = InboxItem(.approval(approval("a")), computer: "name-a")
        XCTAssertEqual(approve.kind, .approval)
        XCTAssertEqual(approve.key, "approve|a|r1")
        XCTAssertEqual(approve.deviceIds, ["a"])
        XCTAssertEqual(approve.stateWord, "Needs approval")
        XCTAssertEqual(approve.tone, .red)
        XCTAssertEqual(approve.sourceParts, ["sudo"])
        XCTAssertEqual(approve.title, "Approve sudo on host?")
        var enrollRequest = approval("a")
        enrollRequest.kind = .enroll
        XCTAssertEqual(InboxItem(.approval(enrollRequest), computer: "name-a").title, "Enroll \(noun) on host?")

        let pair = InboxItem(.pair(deviceId: "new"), computer: "name-new")
        XCTAssertEqual(pair.kind, .pairRequest)
        XCTAssertEqual(pair.key, "pair|new")
        XCTAssertTrue(pair.deviceIds.isEmpty, "a pair request shows in every scope")
        XCTAssertEqual(pair.stateWord, "Pair request")
        XCTAssertEqual(pair.tone, .red)
        XCTAssertEqual(pair.sourceParts, [])
        XCTAssertEqual(pair.title, "name-new asks to pair")
    }

    @MainActor
    func testFinishSetsTheEndTime() {
        let model = ShareModel(downloadFolder: FileManager.default.temporaryDirectory)
        let t = FileTransfer(deviceId: "a", name: "f.pdf", incoming: true, size: 10)
        model.start(t)
        XCTAssertNil(model.transfers.first?.ended, "a running transfer has no end time")
        model.finish(t.id, file: nil, error: nil)
        XCTAssertNotNil(model.transfers.first?.ended)
        XCTAssertEqual(model.transfers.first?.state, .done)
    }
}
