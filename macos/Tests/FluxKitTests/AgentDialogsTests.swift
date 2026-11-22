import XCTest
@testable import FluxKit

/// Ported from AgentDialogsTest.kt of the Android app, with the same vectors.
final class AgentDialogsTests: XCTestCase {
    /// A fake app: it records the reads and runs the timers by hand.
    private final class Io: DialogIo {
        var open = false
        var reading = false
        var reachable = true
        var requests = 0
        var sends: [String] = []
        var screenReads: [String] = []
        var timers: [() -> Void] = []

        func screenOpen(_ deviceId: String, _ pane: String) -> Bool { open }
        func screenReading(_ deviceId: String, _ pane: String) -> Bool { reading }
        func readScreen(_ deviceId: String, _ pane: String) -> Bool {
            screenReads.append(pane)
            return reachable
        }

        func send(_ deviceId: String, _ pane: String, register: (Int) -> Void) -> Bool {
            requests += 1
            register(requests)
            sends.append(pane)
            return reachable
        }

        func now() -> Date { Date(timeIntervalSince1970: 1) }
        func later(_ delay: Duration, _ task: @escaping () -> Void) { timers.append(task) }
        func post(_ task: @escaping () -> Void) { task() }
    }

    private let three = "Bash command\n\n   bin/migrate --apply\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, always\n   3. No\n"
    private let changed = "Bash command\n\n   bin/migrate --rollback\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"

    private func out(_ text: String, request: Int? = nil, pane: String = "w2:p1") -> HerdrOutput {
        HerdrOutput(pane: pane, loading: false, lines: TermText.lines(text), request: request)
    }

    private func parse(_ text: String) throws -> AgentDialog {
        try XCTUnwrap(parseDialog(out(text), at: Date(timeIntervalSince1970: 5)))
    }

    func testParsesTheQuestionTheChoicesAndAnId() throws {
        let d = try parse(three)
        XCTAssertEqual(d.question, "Do you want to proceed?")
        XCTAssertEqual(d.choices.map(\.label), ["Yes", "Yes, always", "No"])
        XCTAssertEqual(d.id.count, 16)
        XCTAssertEqual(d.id, try parse(three).id)
        XCTAssertNotEqual(d.id, try parse(changed).id)
        var failed = out(three)
        failed.error = "x"
        XCTAssertNil(parseDialog(failed, at: Date()))
    }

    func testTheIdIsTheSha256PrefixOfTheQuestionTheLinesAndTheLabels() {
        // The same ID as the Android app gives for the same dialog.
        XCTAssertEqual(dialogId(question: "Q?", lines: ["a"], labels: ["Yes", "No"]), dialogId(question: "Q?", lines: ["a"], labels: ["Yes", "No"]))
        XCTAssertNotEqual(dialogId(question: "Q?", lines: ["a"], labels: ["Yes", "No"]), dialogId(question: "Q?", lines: [], labels: ["a", "Yes", "No"]),
                          "a line and a label do not mix")
        XCTAssertEqual(dialogId(question: "", lines: [], labels: []).count, 16)
    }

    func testAFreeTextQuestionHasNoChoices() throws {
        let d = try parse("I can migrate one.\n\n Which database should I migrate: staging or production?\n")
        XCTAssertTrue(d.choices.isEmpty)
        XCTAssertEqual(d.question, "Which database should I migrate: staging or production?")
    }

    func testReadsEachPaneOnce() {
        let io = Io()
        let book = DialogBook(io: io)
        var got: [AgentDialog?] = []
        book.peek("d", "w2:p1") { got.append($0) }
        book.peek("d", "w2:p1") { got.append($0) }
        XCTAssertEqual(io.sends.count, 1, "a second call joins the read")
        XCTAssertTrue(book.onOutput("d", out(three, request: 1)))
        XCTAssertEqual(got.count, 2)
        XCTAssertNotNil(got[0])
        XCTAssertEqual(got[0], book.latest("d", "w2:p1"))
        book.peek("d", "w2:p2") { _ in }
        XCTAssertEqual(io.sends.count, 2, "another pane has its own read")
    }

    func testAnOpenScreenSharesItsRead() {
        let io = Io()
        io.open = true
        io.reading = true
        let book = DialogBook(io: io)
        var got: AgentDialog?
        book.peek("d", "w2:p1") { got = $0 }
        XCTAssertTrue(io.sends.isEmpty && io.screenReads.isEmpty, "no read of its own")
        XCTAssertFalse(book.onOutput("d", out(three, request: 7)), "the screen keeps the output")
        book.onScreenOutput("d", out(three, request: 7))
        XCTAssertEqual(got?.question, "Do you want to proceed?")
    }

    func testAnOpenScreenWithNoReadAsksTheScreenToRead() {
        let io = Io()
        io.open = true
        DialogBook(io: io).peek("d", "w2:p1") { _ in }
        XCTAssertEqual(io.screenReads, ["w2:p1"])
        XCTAssertTrue(io.sends.isEmpty)
    }

    func testAPeekAnswerIsNotForTheScreen() {
        let io = Io()
        let book = DialogBook(io: io)
        book.peek("d", "w2:p1") { _ in }
        XCTAssertTrue(book.takes("d", "w2:p1", request: 1))
        XCTAssertFalse(book.takes("d", "w2:p1", request: 2))
        XCTAssertTrue(book.takes("d", "w2:p1", request: nil), "an older computer sends no number")
        XCTAssertTrue(book.onOutput("d", out(three, request: 1)))
        XCTAssertFalse(book.onOutput("d", out(three, request: 99)), "an output of another request goes to the screen")
    }

    func testSameIdSendsTheKeysOfTheNewRead() throws {
        let io = Io()
        let book = DialogBook(io: io)
        let id = try parse(three).id
        var same: AgentDialog?
        var other: AgentDialog?
        book.verify("d", "w2:p1", id: id, onSame: { same = $0 }, onChanged: { other = $0 })
        book.onOutput("d", out(three, request: 1))
        XCTAssertEqual(same?.choices[1].keys, ["2"])
        XCTAssertNil(other)
    }

    func testAChangedDialogSendsNothing() throws {
        let io = Io()
        let book = DialogBook(io: io)
        let id = try parse(three).id
        var same: AgentDialog?
        var other: AgentDialog?
        book.verify("d", "w2:p1", id: id, onSame: { same = $0 }, onChanged: { other = $0 })
        book.onOutput("d", out(changed, request: 1))
        XCTAssertNil(same)
        XCTAssertEqual(other?.choices.map(\.label), ["Yes", "No"])
    }

    func testAMenuChoiceGetsTheArrowsFromTheNewSelection() throws {
        // The selected choice is the one with the other background. The new read selects Allow always.
        func menu(_ selected: Int) -> HerdrOutput {
            var bgs = ["44", "44", "44"]
            bgs[selected] = "46"
            let labels = ["Allow once", "Allow always", "Reject"]
            let row = labels.enumerated().map { "\u{1b}[48;5;\(bgs[$0.offset])m \($0.element) \u{1b}[0m" }.joined(separator: "  ") + "   ⇆ select  enter confirm"
            return HerdrOutput(pane: "w2:p1", loading: false, lines: TermText.lines("Permission required\n\n\(row)\n"), request: 1)
        }
        let first = try XCTUnwrap(parseDialog(menu(0), at: Date()))
        let second = try XCTUnwrap(parseDialog(menu(1), at: Date()))
        XCTAssertEqual(first.choices[1].keys, ["right", "enter"])
        XCTAssertEqual(second.choices[1].keys, ["enter"], "the selection moved, so the keys differ")
    }

    func testATimeoutSendsNothing() {
        let io = Io()
        let book = DialogBook(io: io)
        var got: [AgentDialog?] = []
        var calls = 0
        book.verify("d", "w2:p1", id: "x", onSame: { got.append($0); calls += 1 }, onChanged: { got.append($0); calls += 1 })
        XCTAssertEqual(calls, 0)
        io.timers[0]()
        XCTAssertEqual(calls, 1)
        XCTAssertNil(got[0])
        // A late answer finds no waiting read.
        XCTAssertFalse(book.onOutput("d", out(three, request: 1)))
        io.timers[0]()
        XCTAssertEqual(calls, 1, "a second timer call does nothing")
    }

    func testATimerOfAnOldReadDoesNotEndANewRead() {
        let io = Io()
        let book = DialogBook(io: io)
        book.peek("d", "w2:p1") { _ in }
        book.onOutput("d", out(three, request: 1))
        var calls = 0
        book.peek("d", "w2:p1") { _ in calls += 1 }
        io.timers[0]()
        XCTAssertEqual(calls, 0)
    }

    func testAnUnreachableComputerGivesNil() {
        let io = Io()
        io.reachable = false
        var called = false
        var got: AgentDialog? = try? parse(three)
        DialogBook(io: io).peek("d", "w2:p1") { called = true; got = $0 }
        XCTAssertTrue(called)
        XCTAssertNil(got)
    }

    func testAnOlderComputerAnswersWithNoRequestNumber() {
        let io = Io()
        let book = DialogBook(io: io)
        var got: AgentDialog?
        book.peek("d", "w2:p1") { got = $0 }
        XCTAssertTrue(book.onOutput("d", out(three, request: nil)))
        XCTAssertNotNil(got)
    }

    func testReplySendsOnlyForTheDialogOfTheNotice() throws {
        let a = try parse("Name the file.\n\n Which name?\n")
        let b = try parse("Name the folder.\n\n Which folder?\n")
        XCTAssertNotEqual(a.id, b.id)
        XCTAssertTrue(replyMatches(a, a.id))
        XCTAssertFalse(replyMatches(b, a.id))
        XCTAssertFalse(replyMatches(nil, a.id))
        XCTAssertFalse(replyMatches(a, ""))
        let withChoices = try parse(three)
        XCTAssertFalse(replyMatches(withChoices, withChoices.id))
    }
}
