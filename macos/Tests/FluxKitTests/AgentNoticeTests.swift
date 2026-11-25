import XCTest
@testable import FluxKit

/// Ported from AgentNoticeTest.kt of the Android app, with the same vectors.
/// It covers AC84, AC85, and AC86.
final class AgentNoticeTests: XCTestCase {
    private let blocked = HerdrAgent(pane: "w2:p1", agent: "codex", status: .blocked, title: "Run the database migration",
                                     project: "billing", workspace: "billing")

    private func dialog(_ labels: [String], question: String = "Do you want to proceed?", lines: [String] = ["$ bin/migrate --apply"]) -> AgentDialog {
        AgentDialog(question: question, lines: lines, choices: labels.enumerated().map { AgentChoice(String($0.offset + 1), $0.element) },
                    command: true, id: dialogId(question: question, lines: lines, labels: labels), at: Date(timeIntervalSince1970: 0))
    }

    func testTwoChoicesGiveChoiceActions() {
        let n = agentNotice(blocked, dialog: dialog(["Yes", "No"]), control: true)
        XCTAssertEqual(n.actions.map(\.label), ["Yes", "No"])
        XCTAssertEqual(n.actions.map(\.key), ["1", "2"])
        XCTAssertTrue(n.actions.allSatisfy { $0.kind == .choice })
        XCTAssertEqual(n.title, "codex in billing needs input")
    }

    func testThreeChoicesGiveChoiceActionsAndNoReply() {
        let n = agentNotice(blocked, dialog: dialog(["Yes", "Yes, and do not ask again", "No"]), control: true)
        XCTAssertEqual(n.actions.count, 3)
        XCTAssertTrue(n.actions.allSatisfy { $0.kind != .reply })
        XCTAssertTrue(n.text.contains("bin/migrate --apply") && n.text.hasSuffix("Do you want to proceed?"), "the text has the command and the question")
    }

    func testFourChoicesGiveNoAction() {
        let n = agentNotice(blocked, dialog: dialog(["Yes", "Always", "No", "Tell it what to do"]), control: true)
        XCTAssertTrue(n.actions.isEmpty)
        XCTAssertTrue(n.bigText.contains("4. Tell it what to do"), "the expanded text lists the 4 choices in full")
    }

    func testNoChoicesGiveReply() {
        let n = agentNotice(blocked, dialog: dialog([], question: "Which database should I migrate?", lines: []), control: true)
        XCTAssertEqual(n.actions, [NoticeAction(.reply, "Reply", "")])
        XCTAssertEqual(n.title, "codex in billing asks a question")
        XCTAssertEqual(n.text, "Which database should I migrate?")
    }

    func testControlOffGivesNoActionAndReadOnly() {
        let n = agentNotice(blocked, dialog: dialog(["Yes", "No"]), control: false)
        XCTAssertTrue(n.actions.isEmpty)
        XCTAssertTrue(n.text.hasSuffix(" Read only"))
        XCTAssertTrue(n.bigText.hasSuffix("\nRead only"))
        let free = agentNotice(blocked, dialog: dialog([], question: "Which one?", lines: []), control: false)
        XCTAssertTrue(free.actions.isEmpty, "Reply is an action too")
    }

    func testControlOnHasNoReadOnlyText() {
        XCTAssertFalse(agentNotice(blocked, dialog: dialog(["Yes", "No"]), control: true).text.contains("Read only"))
    }

    func testAFinishedAgentGivesNoAction() {
        var done = blocked
        done.status = .done
        let n = agentNotice(done, dialog: dialog(["Yes", "No"]), control: true)
        XCTAssertTrue(n.actions.isEmpty)
        XCTAssertEqual(n.title, "codex in billing finished")
        XCTAssertEqual(n.text, "Run the database migration")
        XCTAssertFalse(agentNotice(done, dialog: nil, control: false).text.contains("Read only"), "a finished agent has no Read only text")
    }

    func testAMissingDialogGivesNoActionAndTheTitleOfTheAgent() {
        let n = agentNotice(blocked, dialog: nil, control: true)
        XCTAssertTrue(n.actions.isEmpty)
        XCTAssertEqual(n.text, "Run the database migration")
        XCTAssertEqual(n.title, "codex in billing needs input")
        XCTAssertEqual(agentNotice(blocked, dialog: nil, control: false).text, "Run the database migration Read only")
    }

    func testALongLabelIsCutAtAWordEnd() {
        XCTAssertEqual(cutLabel("Yes, and do not ask again for bin/migrate commands"), "Yes, and do not ask…")
        XCTAssertEqual(cutLabel("No"), "No")
        XCTAssertEqual(cutLabel("exactly twenty-four ch"), "exactly twenty-four ch")
        XCTAssertEqual(cutLabel(String(repeating: "a", count: 40)), String(repeating: "a", count: 24) + "…")
        XCTAssertEqual(cutLabel("one two three four five six"), "one two three four five…")
        let n = agentNotice(blocked, dialog: dialog(["Yes", "Yes, and do not ask again for bin/migrate commands", "No"]), control: true)
        XCTAssertEqual(n.actions[1].label, "Yes, and do not ask…")
        XCTAssertTrue(n.bigText.contains("2. Yes, and do not ask again for bin/migrate commands"), "the expanded text keeps the full label")
    }

    func testTheNoticeCarriesTheIdOfItsDialog() {
        let d = dialog(["Yes", "No"])
        XCTAssertEqual(agentNotice(blocked, dialog: d, control: true).dialogId, d.id)
        XCTAssertEqual(agentNotice(blocked, dialog: nil, control: true).dialogId, "")
    }
}
