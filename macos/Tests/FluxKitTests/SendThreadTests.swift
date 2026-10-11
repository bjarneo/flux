import XCTest
@testable import FluxKit

final class SendThreadTests: XCTestCase {
    private func agent(_ pane: String, _ status: AgentStatus) -> HerdrAgent { HerdrAgent(pane: pane, agent: "claude", status: status) }

    func testClockKnowsOnlyTheChangesThatItSaw() {
        var c = AgentClock()
        let t0 = Date(timeIntervalSince1970: 1_000)
        // The first state after a connection: the start of each status is not known.
        XCTAssertTrue(c.update([agent("a", .blocked), agent("b", .working)], now: t0).isEmpty)
        let t1 = t0.addingTimeInterval(4)
        XCTAssertEqual(c.update([agent("a", .working), agent("b", .working), agent("c", .blocked)], now: t1), ["a": t1, "c": t1])
        // The same status keeps its time, and an unknown status keeps the last status and its time.
        XCTAssertEqual(c.update([agent("a", .unknown), agent("c", .blocked)], now: t1.addingTimeInterval(4)), ["a": t1, "c": t1])
        // A connection again keeps the times that the device saw, and an agent that is gone leaves.
        c.restart()
        XCTAssertEqual(c.update([agent("a", .working), agent("d", .done)], now: t1.addingTimeInterval(7)), ["a": t1])
    }

    func testAgentTimes() {
        let now = Date(timeIntervalSince1970: 10_000_000)
        XCTAssertEqual(AgentTime.when(.done, since: nil, now: now), "done")
        XCTAssertEqual(AgentTime.when(.blocked, since: nil, now: now), "")
        XCTAssertEqual(AgentTime.when(.blocked, since: now.addingTimeInterval(-30), now: now), "now")
        XCTAssertEqual(AgentTime.when(.blocked, since: now.addingTimeInterval(-185), now: now), "3m")
        XCTAssertEqual(AgentTime.when(.idle, since: now.addingTimeInterval(-7200), now: now), "2h")
        XCTAssertEqual(AgentTime.when(.working, since: now.addingTimeInterval(-134), now: now), "2:14")
        XCTAssertEqual(AgentTime.when(.unknown, since: now.addingTimeInterval(-134), now: now), "")
    }

    func testAgoTexts() {
        let now = Date(timeIntervalSince1970: 100_000_000)
        XCTAssertEqual(AgoText.text(now.addingTimeInterval(-20), now: now), "just now")
        XCTAssertEqual(AgoText.text(now.addingTimeInterval(-60), now: now), "1 min ago")
        XCTAssertEqual(AgoText.text(now.addingTimeInterval(-7200), now: now), "2 h ago")
        XCTAssertEqual(AgoText.text(now.addingTimeInterval(-25 * 3600), now: now), "1 day ago")
        XCTAssertEqual(AgoText.text(now.addingTimeInterval(-3 * 24 * 3600), now: now), "3 days ago")
    }

    func testSentItemsKeepAShortTextAndTheNewest() {
        let long = SentItem(deviceId: "pc", kind: .text, text: "  " + String(repeating: "x", count: SentItem.maxText + 50) + "  ")
        XCTAssertEqual(long.text.count, SentItem.maxText)
        XCTAssertTrue(long.text.hasSuffix("…"))
        XCTAssertEqual(SentItem(deviceId: "pc", kind: .link, text: " https://omarchy.org ").text, "https://omarchy.org")
        var list: [SentItem] = []
        for i in 0..<5 { list = ShareModel.appending(list, SentItem(deviceId: "pc", kind: .clip, text: "\(i)", clipStamp: i), max: 3) }
        XCTAssertEqual(list.map(\.text), ["2", "3", "4"])
        XCTAssertEqual(list.last?.clipStamp, 4)
    }

    func testManualClipPackets() {
        let text = ClipboardPlugin.manualClip("git push")
        XCTAssertEqual(text.type, PacketType.clipboard)
        XCTAssertEqual(text.string("content"), "git push")
        XCTAssertEqual(text.bool("manual"), true)
        XCTAssertEqual(ClipImage.packet(mime: "image/png", size: 10, port: 1, manual: true).bool("manual"), true)
        XCTAssertNil(ClipImage.packet(mime: "image/png", size: 10, port: 1).bool("manual"))
    }
}
