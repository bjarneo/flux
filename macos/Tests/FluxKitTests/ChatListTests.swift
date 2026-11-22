import XCTest
@testable import FluxKit

/// Ported from ChatListTest.kt of the Android app.
final class ChatListTests: XCTestCase {
    private func at(_ s: TimeInterval) -> Date { Date(timeIntervalSince1970: s) }

    private func device(_ id: String, _ name: String, paired: Bool = true, online: Bool = true,
                        pairState: PairState = .paired) -> DeviceSnapshot {
        DeviceSnapshot(id: id, name: name, type: "laptop", ip: "", isFlux: true, paired: paired, online: online,
                       pairState: paired ? .paired : pairState, pairKey: "", incoming: [], outgoing: [])
    }

    private let migrate = HerdrAgent(pane: "w2:p1", agent: "codex", status: .blocked, title: "Run the database migration", project: "billing")
    private let refactor = HerdrAgent(pane: "w1:p1", agent: "claude", status: .working, title: "Refactor the sync loop", project: "flux")
    private let flaky = HerdrAgent(pane: "w3:p1", agent: "claude", status: .done, title: "Fix the flaky login test", project: "web")
    private let idle = HerdrAgent(pane: "w3:p2", agent: "pi", status: .idle, project: "web")

    private func herdr(_ agents: [HerdrAgent]) -> HerdrState { HerdrState(enabled: true, running: true, agents: agents, control: true) }

    private func approval(_ computer: String, time: Int64 = 0) -> ApproveRequest {
        ApproveRequest(computerId: computer, computerName: computer, id: "r1", kind: .approve, host: computer,
                       user: "dev", service: "sudo", tty: "pts/3", rhost: "", time: time,
                       nonce: String(repeating: "0", count: 64), timeoutSeconds: 60)
    }

    private func text(_ device: String, _ text: String, _ s: TimeInterval) -> ChatEntry {
        .sent(SentItem(deviceId: device, kind: .text, text: text, at: at(s)))
    }

    private func ids(_ rows: [ChatRow]) -> [String] { rows.map(\.id) }

    func testTheAgentsThatWaitAndTheApprovalAreOnTop() {
        let pc = device("pc", "omarchy-xps")
        let since = ["w2:p1": at(5_000), "w1:p1": at(100), "w3:p1": at(200)]
        var clock = SeenClock()
        let list = Chats.list(devices: [pc], herdr: ["pc": herdr([refactor, migrate, flaky, idle])], approval: approval("pc", time: 1),
                              log: [], since: { _, pane in since[pane] }, seen: &clock, now: at(9_000))
        XCTAssertEqual(ids(list.needs), ["agent|pc|w2:p1", "approve|pc|r1"], "the newest first")
        XCTAssertEqual(list.needs.last?.at, at(1), "an approval takes the time of its request")
        XCTAssertEqual(ids(list.agents), ["agent|pc|w1:p1", "agent|pc|w3:p1", "agent|pc|w3:p2"],
                       "the agents that work come first, then the agents that are done")
    }

    func testAnAgentWithNoStartTakesTheTimeThatTheListSawIt() {
        let pc = device("pc", "omarchy-xps")
        var clock = SeenClock()
        func agentAt(_ agent: HerdrAgent, _ now: TimeInterval) -> Date? {
            Chats.list(devices: [pc], herdr: ["pc": herdr([agent])], approval: nil, log: [], since: { _, _ in nil },
                       seen: &clock, now: at(now)).agents.first?.at
        }
        XCTAssertEqual(agentAt(flaky, 10), at(10))
        XCTAssertEqual(agentAt(flaky, 99), at(10))
        var working = flaky
        working.status = .working
        XCTAssertEqual(agentAt(working, 120), at(120), "a new status is new")
    }

    func testAComputerThatIsNotReachableKeepsItsLastKnownAgentsInTheirGroups() {
        let desk = device("desk", "omarchy-desk", online: false)
        let pc = device("pc", "omarchy-xps")
        var clock = SeenClock()
        let list = Chats.list(devices: [desk, pc], herdr: ["desk": herdr([migrate, flaky]), "pc": herdr([refactor])], approval: nil, log: [],
                              since: { _, _ in nil }, lastSeen: { $0 == "desk" ? self.at(4_000) : nil }, seen: &clock, now: at(9_000))
        XCTAssertEqual(ids(list.needs), ["agent|desk|w2:p1"], "a blocked agent stays in Needs you")
        XCTAssertEqual(ids(list.agents), ["agent|pc|w1:p1", "agent|desk|w3:p1"])
        guard case .agent(_, _, let blocked, _, _, let blockedLink) = list.needs[0],
              case .agent(_, _, let done, _, _, let doneLink) = list.agents[1],
              case .agent(_, _, _, _, _, let worksLink) = list.agents[0] else { return XCTFail("agent rows") }
        XCTAssertEqual(blocked.status, .blocked)
        XCTAssertEqual(blockedLink, AgentLink(reachable: false, since: at(4_000)))
        XCTAssertEqual(done.status, .done, "the agent keeps its group")
        XCTAssertEqual(doneLink, AgentLink(reachable: false, since: at(4_000)))
        XCTAssertEqual(worksLink, AgentLink(reachable: true, since: nil))
        XCTAssertEqual(ids(list.computers), ["computer|pc", "computer|desk"])
    }

    func testAComputerThatIsNotReachableAndHasNoAgentListAddsNoAgents() {
        let desk = device("desk", "omarchy-desk", online: false)
        var clock = SeenClock()
        let list = Chats.list(devices: [desk], herdr: [:], approval: nil, log: [],
                              since: { _, _ in nil }, seen: &clock, now: at(1))
        XCTAssertTrue(list.needs.isEmpty)
        XCTAssertTrue(list.agents.isEmpty)
        XCTAssertEqual(ids(list.computers), ["computer|desk"])
    }

    func testTheRowOfAnAgentOfAComputerThatIsNotReachableSaysWhenFluxSawTheComputer() {
        var clock = SeenClock()
        let desk = device("desk", "omarchy-desk", online: false)
        let list = Chats.list(devices: [desk], herdr: ["desk": herdr([migrate])], approval: nil, log: [],
                              since: { _, _ in nil }, lastSeen: { _ in self.at(5_000) }, seen: &clock, now: at(9_000))
        guard case .agent(_, _, _, _, _, let link) = list.needs[0] else { return XCTFail("agent row") }
        XCTAssertEqual(LinkNote.rowLine(online: link.reachable, lastSeen: link.since, time: { _ in "14:02" }), "Not reachable since 14:02")
        let unknown = Chats.list(devices: [desk], herdr: ["desk": herdr([migrate])], approval: nil, log: [],
                                 since: { _, _ in nil }, seen: &clock, now: at(9_000))
        guard case .agent(_, _, _, _, _, let none) = unknown.needs[0] else { return XCTFail("agent row") }
        XCTAssertEqual(LinkNote.rowLine(online: none.reachable, lastSeen: none.since, time: { _ in "14:02" }), "Not reachable")
    }

    func testEachComputerShowsItsNewestEntryAndTheOnlineComputersComeFirst() {
        let pc = device("pc", "omarchy-xps")
        let desk = device("desk", "omarchy-desk", online: false)
        let other = device("other", "work-thinkpad")
        let file = ChatEntry.file(FileTransfer(deviceId: "pc", name: "invoice.pdf", incoming: true, size: 10, state: .done, started: at(50)))
        let log = [text("pc", "Dinner at 7", 100), file, text("desk", "notes", 900)]
        var clock = SeenClock()
        let list = Chats.list(devices: [desk, other, pc], herdr: [:], approval: nil, log: log,
                              since: { _, _ in nil }, seen: &clock, now: at(1_000))
        XCTAssertEqual(ids(list.computers), ["computer|pc", "computer|other", "computer|desk"])
        guard case .computer(_, let last) = list.computers[0], case .computer(_, let none) = list.computers[1] else {
            return XCTFail("computers")
        }
        XCTAssertEqual(last?.preview, "You: Dinner at 7")
        XCTAssertNil(none)
        XCTAssertEqual(file.preview, "invoice.pdf")
    }

    func testAPairRequestNeedsTheUserAndAnApprovalOfAnotherComputerDoesNotShow() {
        let pc = device("pc", "omarchy-xps")
        let new = device("new", "framework-13", paired: false, pairState: .incoming)
        var clock = SeenClock()
        let list = Chats.list(devices: [pc, new], herdr: [:], approval: approval("gone"), log: [],
                              since: { _, _ in nil }, seen: &clock, now: at(1))
        XCTAssertEqual(ids(list.needs), ["pair|new"])
        XCTAssertEqual(ids(list.computers), ["computer|pc"])
    }

    func testTheSearchKeepsTheRowsThatHoldItAndShowsTheEntryThatMatches() {
        let pc = device("pc", "omarchy-xps")
        let desk = device("desk", "omarchy-desk")
        let file = ChatEntry.file(FileTransfer(deviceId: "pc", name: "invoice-0042.pdf", incoming: true, size: 10, state: .done, started: at(10)))
        let log = [file, text("pc", "Dinner at 7", 20), text("desk", "notes", 30)]
        let state = ["pc": herdr([migrate, flaky])]
        var clock = SeenClock()
        let byFile = Chats.list(devices: [pc, desk], herdr: state, approval: nil, log: log, since: { _, _ in nil },
                                seen: &clock, now: at(100), query: "INVOICE")
        XCTAssertTrue(byFile.needs.isEmpty)
        XCTAssertTrue(byFile.agents.isEmpty)
        XCTAssertEqual(ids(byFile.computers), ["computer|pc"])
        guard case .computer(_, let match) = byFile.computers.first else { return XCTFail("computer") }
        XCTAssertEqual(match?.text, "invoice-0042.pdf")
        let byProject = Chats.list(devices: [pc, desk], herdr: state, approval: nil, log: log, since: { _, _ in nil },
                                   seen: &clock, now: at(100), query: "billing")
        XCTAssertEqual(ids(byProject.needs), ["agent|pc|w2:p1"])
        let byName = Chats.list(devices: [pc, desk], herdr: state, approval: nil, log: log, since: { _, _ in nil },
                                seen: &clock, now: at(100), query: "desk")
        guard case .computer(_, let newest) = byName.computers.first else { return XCTFail("desk") }
        XCTAssertEqual(newest?.text, "notes", "a computer that matches by name shows its newest entry")
    }
}
