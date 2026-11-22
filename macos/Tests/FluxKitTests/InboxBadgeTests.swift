import XCTest
@testable import FluxKit

/// The badge rule of the Apple inbox: AC41. A blocked agent of a computer
/// that is not reachable stays in Needs you and in the badge. This file has
/// no dependency on the core, so that the scratch package can run it.
final class InboxBadgeTests: XCTestCase {
    private func device(_ id: String, online: Bool) -> DeviceSnapshot {
        DeviceSnapshot(id: id, name: "name-\(id)", type: "laptop", ip: "", isFlux: true, paired: true, online: online,
                       pairState: .paired, pairKey: "", incoming: [], outgoing: [])
    }

    private func agents(_ list: [HerdrAgent]) -> HerdrState {
        HerdrState(enabled: true, running: true, agents: list, control: true)
    }

    private let working = HerdrAgent(pane: "w1:p1", agent: "claude", status: .working, title: "Refactor")
    private let blocked = HerdrAgent(pane: "w2:p1", agent: "codex", status: .blocked, title: "Migrate")
    private let done = HerdrAgent(pane: "w3:p1", agent: "claude", status: .done, title: "Fix test")

    func testABlockedAgentOfAnOfflineComputerStaysInTheBadge() {
        let items = Inbox.items(devices: [device("a", online: false)], herdr: ["a": agents([working, blocked, done])], approval: nil)
        XCTAssertEqual(items.map { $0.kind }, [.agentInput])
        XCTAssertEqual(Inbox.needsYou(items), 1)
    }

    func testTheBadgeCountsOnlineAndOfflineComputersTogether() {
        let other = HerdrAgent(pane: "w9:p1", agent: "pi", status: .blocked, title: "Ask")
        let items = Inbox.items(devices: [device("a", online: false), device("b", online: true)],
                                herdr: ["a": agents([blocked]), "b": agents([other, done])], approval: nil)
        XCTAssertEqual(Inbox.needsYou(items), 2)
        XCTAssertEqual(items.count, 3)
    }

    func testAnOfflineComputerWithNoAgentListAddsNothing() {
        XCTAssertTrue(Inbox.items(devices: [device("a", online: false)], herdr: [:], approval: nil).isEmpty)
    }
}
