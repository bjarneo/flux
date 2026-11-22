import UserNotifications
import XCTest
@testable import FluxKit

/// The answer from the notification of an agent: AC84 to AC88. The pure
/// models have their own tests in AgentNoticeTests and AgentDialogsTests.
/// These tests replace the link and the unlock of the app.
final class HerdrNoticeTests: XCTestCase {
    private let three = "Bash command\n\n   bin/migrate --apply\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. Yes, always\n   3. No\n"
    private let other = "Bash command\n\n   bin/migrate --rollback\n\n Do you want to proceed?\n ❯ 1. Yes\n   2. No\n"
    private let free = "I can migrate one.\n\n Which database should I migrate: staging or production?\n"

    private let blocked = HerdrAgent(pane: "w2:p1", agent: "codex", status: .blocked, title: "Run the database migration", project: "billing")

    /// What the app does around the plugin: the packets that go out, the unlocks that it was asked for, the threads that it opened.
    private final class Harness {
        var packets: [Packet] = []
        var unlocks: [@MainActor () -> Void] = []
        var errors: [@MainActor (String) -> Void] = []
        var opened: [String] = []
        var computers: [String] = []
    }

    @MainActor
    private func makePlugin(control: Bool = true, linkOpen: Bool = true, agent: HerdrAgent? = nil) -> (HerdrPlugin, Harness) {
        let plugin = HerdrPlugin()
        let h = Harness()
        plugin.model.states["pc"] = HerdrState(enabled: true, running: true, agents: [agent ?? blocked], control: control)
        plugin.linkProbe = { _ in linkOpen }
        plugin.sender = { packet, _ in
            h.packets.append(packet)
            return true
        }
        plugin.model.unlock = { computer, action, onError in
            h.computers.append(computer)
            h.unlocks.append(action)
            h.errors.append(onError)
        }
        plugin.model.open = { device, pane in h.opened.append("\(device)|\(pane)") }
        return (plugin, h)
    }

    private func dialogId(_ text: String) throws -> String {
        let out = HerdrOutput(pane: "w2:p1", loading: false, lines: TermText.lines(text))
        return try XCTUnwrap(parseDialog(out, at: Date())).id
    }

    private func output(_ text: String, request: Int) -> Packet {
        let json = String(decoding: JSONValue.string(text).serialized(), as: UTF8.self)
        return Packet.parse(#"{"id":1,"type":"flux.herdr","body":{"kind":"output","pane":"w2:p1","format":"ansi","request":\#(request),"text":\#(json)}}"#)!
    }

    private func kinds(_ h: Harness) -> [String] { h.packets.compactMap { $0.string("kind") } }

    @MainActor
    private func waitFor(_ done: @MainActor () -> Bool) async throws {
        var waited = 0
        while !done(), waited < 60 {
            try await Task.sleep(for: .milliseconds(50))
            waited += 1
        }
    }

    /// Runs the unlock, then answers the dialog read with `text`.
    @MainActor
    private func unlockAndRead(_ plugin: HerdrPlugin, _ h: Harness, _ text: String) async throws {
        XCTAssertEqual(h.unlocks.count, 1)
        h.unlocks[0]()
        XCTAssertEqual(kinds(h), ["read"], "after the unlock the app reads the pane again")
        let request = try XCTUnwrap(h.packets[0].int("request"))
        XCTAssertEqual(h.packets[0].int("lines"), dialogReadLines)
        plugin.receive(output(text, request: request), deviceId: "pc", computer: "desk")
        try await waitFor { h.packets.count > 1 || !h.opened.isEmpty }
    }

    // AC87: the unlock comes first.

    @MainActor
    func testAChoiceSendsNothingBeforeTheUnlock() throws {
        let (plugin, h) = makePlugin()
        plugin.noticeAction("choice.2", deviceId: "pc", pane: "w2:p1", dialog: try dialogId(three), text: nil)
        XCTAssertEqual(h.unlocks.count, 1, "the app asks for the unlock")
        XCTAssertEqual(h.computers, ["The computer"], "the unlock names the computer")
        XCTAssertTrue(h.packets.isEmpty, "no read and no key before the unlock")
        XCTAssertTrue(h.opened.isEmpty)
    }

    @MainActor
    func testAFailedUnlockOpensTheThreadAndSendsNothing() throws {
        let (plugin, h) = makePlugin()
        plugin.noticeAction("choice.1", deviceId: "pc", pane: "w2:p1", dialog: try dialogId(three), text: nil)
        h.errors[0]("The check failed")
        XCTAssertTrue(h.packets.isEmpty)
        XCTAssertEqual(h.opened, ["pc|w2:p1"])
        XCTAssertFalse(plugin.model.isQuestionChanged("pc", pane: "w2:p1"))
        XCTAssertEqual(plugin.model.reply("pc", pane: "w2:p1")?.error, "The check failed", "the thread shows why nothing went out")
    }

    @MainActor
    func testAnAppWithNoUnlockSendsNothingAndOpensTheThread() throws {
        let (plugin, h) = makePlugin()
        plugin.model.unlock = nil
        plugin.noticeAction("choice.1", deviceId: "pc", pane: "w2:p1", dialog: try dialogId(three), text: nil)
        XCTAssertTrue(h.packets.isEmpty)
        XCTAssertEqual(h.opened, ["pc|w2:p1"])
    }

    // AC84 and AC85: the actions send the choice and the reply.

    @MainActor
    func testAChoiceSendsItsKeysWhenTheDialogIsTheSame() async throws {
        let (plugin, h) = makePlugin()
        plugin.noticeAction("choice.2", deviceId: "pc", pane: "w2:p1", dialog: try dialogId(three), text: nil)
        try await unlockAndRead(plugin, h, three)
        XCTAssertEqual(kinds(h), ["read", "keys"])
        XCTAssertEqual(h.packets[1].strings("keys"), ["2"])
        XCTAssertTrue(h.opened.isEmpty, "a send does not open the thread")
    }

    @MainActor
    func testAReplySendsAsAnAnswerWhenTheQuestionIsTheSame() async throws {
        let (plugin, h) = makePlugin()
        plugin.noticeAction("reply", deviceId: "pc", pane: "w2:p1", dialog: try dialogId(free), text: "staging")
        try await unlockAndRead(plugin, h, free)
        XCTAssertEqual(kinds(h), ["read", "prompt"])
        XCTAssertEqual(h.packets[1].string("text"), "staging")
        XCTAssertEqual(h.packets[1].bool("answer"), true, "the text answers the dialog, as Send as answer does")
    }

    @MainActor
    func testAReplyWithNoTextSendsNothing() throws {
        let (plugin, h) = makePlugin()
        plugin.noticeAction("reply", deviceId: "pc", pane: "w2:p1", dialog: try dialogId(free), text: "  ")
        XCTAssertTrue(h.unlocks.isEmpty)
        XCTAssertTrue(h.packets.isEmpty)
    }

    // AC88: a changed output or a closed link sends nothing.

    @MainActor
    func testAChangedQuestionSendsNothingAndOpensTheThread() async throws {
        let (plugin, h) = makePlugin()
        plugin.noticeAction("choice.1", deviceId: "pc", pane: "w2:p1", dialog: try dialogId(three), text: nil)
        try await unlockAndRead(plugin, h, other)
        XCTAssertEqual(kinds(h), ["read"], "no key goes out")
        XCTAssertEqual(h.opened, ["pc|w2:p1"])
        XCTAssertTrue(plugin.model.isQuestionChanged("pc", pane: "w2:p1"), "the thread says that the question changed")
        plugin.closeOutput("pc", pane: "w2:p1")
        XCTAssertFalse(plugin.model.isQuestionChanged("pc", pane: "w2:p1"), "the note goes when the thread closes")
    }

    @MainActor
    func testAReplyToAChangedQuestionSendsNothing() async throws {
        let (plugin, h) = makePlugin()
        plugin.noticeAction("reply", deviceId: "pc", pane: "w2:p1", dialog: try dialogId(free), text: "staging")
        try await unlockAndRead(plugin, h, three)
        XCTAssertEqual(kinds(h), ["read"])
        XCTAssertEqual(h.opened, ["pc|w2:p1"])
    }

    @MainActor
    func testAClosedLinkSendsNothingAndOpensTheThread() throws {
        let (plugin, h) = makePlugin(linkOpen: false)
        plugin.noticeAction("choice.1", deviceId: "pc", pane: "w2:p1", dialog: try dialogId(three), text: nil)
        XCTAssertTrue(h.unlocks.isEmpty, "no unlock for an answer that cannot go")
        XCTAssertTrue(h.packets.isEmpty)
        XCTAssertEqual(h.opened, ["pc|w2:p1"])
    }

    @MainActor
    func testALinkThatClosesAfterTheUnlockSendsNothing() throws {
        let (plugin, h) = makePlugin()
        var open = true
        plugin.linkProbe = { _ in open }
        plugin.noticeAction("choice.1", deviceId: "pc", pane: "w2:p1", dialog: try dialogId(three), text: nil)
        open = false
        h.unlocks[0]()
        XCTAssertTrue(h.packets.isEmpty)
        XCTAssertEqual(h.opened, ["pc|w2:p1"])
    }

    @MainActor
    func testAnAgentThatNoLongerWaitsGetsNoAnswer() throws {
        var working = blocked
        working.status = .working
        let (plugin, h) = makePlugin(agent: working)
        plugin.noticeAction("choice.1", deviceId: "pc", pane: "w2:p1", dialog: try dialogId(three), text: nil)
        XCTAssertTrue(h.unlocks.isEmpty)
        XCTAssertTrue(h.packets.isEmpty)
        XCTAssertEqual(h.opened, ["pc|w2:p1"])
    }

    // AC86: with Agent control off, nothing goes out.

    @MainActor
    func testWithAgentControlOffAnActionSendsNothing() throws {
        let (plugin, h) = makePlugin(control: false)
        plugin.noticeAction("choice.1", deviceId: "pc", pane: "w2:p1", dialog: try dialogId(three), text: nil)
        XCTAssertTrue(h.unlocks.isEmpty)
        XCTAssertTrue(h.packets.isEmpty)
        XCTAssertEqual(h.opened, ["pc|w2:p1"])
    }

    @MainActor
    func testATapOnTheNotificationOpensTheThread() {
        let (plugin, h) = makePlugin()
        plugin.noticeAction(UNNotificationDefaultActionIdentifier, deviceId: "pc", pane: "w2:p1", dialog: "", text: nil)
        XCTAssertEqual(h.opened, ["pc|w2:p1"])
        XCTAssertTrue(h.packets.isEmpty)
        plugin.noticeAction(UNNotificationDismissActionIdentifier, deviceId: "pc", pane: "w2:p1", dialog: "", text: nil)
        XCTAssertEqual(h.opened.count, 1, "a swipe away does nothing")
    }

    // The actions of the category.

    func testAnIPhoneAsksForTheUnlockOnEachActionAndComesToTheFront() throws {
        let choices = [NoticeAction(.choice, "Yes", "1"), NoticeAction(.choice, "No", "2")]
        let phone = HerdrPlugin.notificationActions(choices, platform: .phone)
        XCTAssertEqual(phone.map(\.identifier), ["choice.1", "choice.2"])
        XCTAssertEqual(phone.map(\.title), ["Yes", "No"])
        XCTAssertTrue(phone.allSatisfy { $0.options.contains(.authenticationRequired) && $0.options.contains(.foreground) })
        let mac = HerdrPlugin.notificationActions(choices, platform: .mac)
        XCTAssertTrue(mac.allSatisfy { !$0.options.contains(.authenticationRequired) }, "the Mac asks Touch ID in the app")
    }

    func testReplyTakesText() throws {
        let actions = HerdrPlugin.notificationActions([NoticeAction(.reply, "Reply", "")], platform: .phone)
        XCTAssertEqual(actions.map(\.identifier), ["reply"])
        let text = try XCTUnwrap(actions.first as? UNTextInputNotificationAction)
        XCTAssertEqual(text.textInputButtonTitle, "Send")
    }

    func testTheCategoryOfADialogKeepsTheFamilyOfTheHandler() {
        let id = HerdrPlugin.categoryId(dialog: "3fa9c0de11223344")
        XCTAssertEqual(id, "herdr:3fa9c0de11223344")
        XCTAssertEqual(Notifier.family(id), HerdrPlugin.notificationCategory, "an older notification still reaches the handler after a restart")
        XCTAssertEqual(Notifier.family("share.file"), "share.file")
    }
}
