import XCTest
@testable import FluxKit

/// Ported from InboxModelTest.kt of the Android app, plus the text of the items.
final class InboxModelTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 0)

    private func device(_ id: String, paired: Bool = true, online: Bool = true, pairState: PairState? = nil) -> DeviceSnapshot {
        let state: PairState = pairState ?? (paired ? PairState.paired : PairState.none)
        return DeviceSnapshot(id: id, name: "name-\(id)", type: "laptop", ip: "", isFlux: true, paired: paired, online: online,
                              pairState: state, pairKey: "", incoming: [], outgoing: [])
    }

    private func agents(_ list: [HerdrAgent]) -> HerdrState {
        HerdrState(enabled: true, running: true, agents: list, control: true)
    }

    private func player(_ name: String, title: String = "", artist: String = "", playing: Bool = false) -> RemotePlayer {
        var p = RemotePlayer(name: name)
        p.title = title
        p.artist = artist
        p.playing = playing
        return p
    }

    private func media(_ p: RemotePlayer) -> RemoteMedia {
        var m = RemoteMedia()
        m.players = [p.name]
        m.current = p.name
        m.states = [p.name: p]
        return m
    }

    private func approval(_ computer: String) -> ApproveRequest {
        ApproveRequest(computerId: computer, computerName: "name-\(computer)", id: "r1", kind: .approve, host: "host",
                       user: "user", service: "sudo", tty: "pts/1", rhost: "", time: 0,
                       nonce: String(repeating: "0", count: 64), timeoutSeconds: 60)
    }

    private func transfer(_ name: String, incoming: Bool = true, state: FileTransfer.State = .running,
                          started: Date, ended: Date? = nil) -> FileTransfer {
        FileTransfer(deviceId: "a", name: name, incoming: incoming, size: 0, state: state, started: started, ended: ended)
    }

    /// The items at the time 0, with every player seen at the time 0.
    private func inbox(_ devices: [DeviceSnapshot], herdr: [String: HerdrState] = [:], media: [String: RemoteMedia] = [:],
                       approval: ApproveRequest? = nil, transfers: [FileTransfer] = [], clip: ClipEvent? = nil) -> [InboxItem] {
        let playedAt = Dictionary(devices.map { ($0.id, t0) }, uniquingKeysWith: { first, _ in first })
        return Inbox.items(devices: devices, herdr: herdr, media: media, approval: approval, transfers: transfers, clip: clip,
                           now: t0, playedAt: playedAt)
    }

    private func agentOf(_ item: InboxItem) -> HerdrAgent? {
        if case .agent(_, let agent, _) = item.content { return agent }
        return nil
    }

    private func transferOf(_ item: InboxItem) -> FileTransfer? {
        if case .transfer(let t) = item.content { return t }
        return nil
    }

    private func mediaDevice(_ item: InboxItem) -> String? {
        if case .media(let deviceId, _) = item.content { return deviceId }
        return nil
    }

    private let working = HerdrAgent(pane: "w1:p1", agent: "claude", status: .working, title: "Refactor")
    private let blocked = HerdrAgent(pane: "w2:p1", agent: "codex", status: .blocked, title: "Migrate")
    private let done = HerdrAgent(pane: "w3:p1", agent: "claude", status: .done, title: "Fix test")
    private let idle = HerdrAgent(pane: "w3:p2", agent: "pi", status: .idle)

    func testWhatNeedsTheUserComesFirst() {
        let devices = [device("a"), device("new", paired: false, pairState: .incoming)]
        let clip = ClipEvent(deviceIds: ["a"], computer: "name-a", sent: true, preview: "text", at: t0)
        let items = inbox(devices, herdr: ["a": agents([working, blocked, done, idle])],
                          media: ["a": media(player("Spotify", title: "Song", playing: true))],
                          approval: approval("a"), transfers: [transfer("f.pdf", started: t0)], clip: clip)
        XCTAssertEqual(items.map { $0.kind },
                       [.agentInput, .approval, .pairRequest, .media, .clipboard, .transfer, .agentDone, .agentWorking],
                       "what needs the user, then what plays, the clip, and the transfers, then the agents that do not wait")
        XCTAssertEqual(items.compactMap { agentOf($0) }.filter { $0.status == .idle }.count, 0, "an idle agent is not news")
        XCTAssertEqual(Inbox.needsYou(items), 3)
    }

    func testAComputerThatIsNotReachableAddsNoAgentsAndNoPlayer() {
        let d = device("a", online: false)
        let items = inbox([d], herdr: ["a": agents([blocked])], media: ["a": media(player("mpv", title: "x", playing: true))])
        XCTAssertTrue(items.isEmpty)
    }

    func testRunningTransfersComeFirstThenTheNewest() {
        let old = transfer("old", state: .done, started: Date(timeIntervalSince1970: 10))
        let newer = transfer("new", state: .failed("x"), started: Date(timeIntervalSince1970: 20))
        let run = transfer("run", incoming: false, started: Date(timeIntervalSince1970: 5))
        let names = inbox([], transfers: [old, newer, run]).compactMap { transferOf($0)?.name }
        XCTAssertEqual(names, ["run", "new", "old"])
    }

    func testAPlayingPlayerComesBeforeAPausedOne() {
        let devices = [device("a"), device("b"), device("c")]
        let players = ["a": media(player("mpv", title: "Paused song")),
                       "b": media(player("Spotify", title: "Song", playing: true)),
                       "c": media(player("Firefox"))]
        let ids = inbox(devices, media: players).compactMap { mediaDevice($0) }
        XCTAssertEqual(ids, ["b", "a"], "a paused player without a title is not news")
    }

    func testFinishedTransfersAndTheClipLeaveAfterTheKeepTime() {
        let now = Date(timeIntervalSince1970: 10 * Inbox.keep)
        let run = transfer("run", started: t0)
        let done = transfer("done", state: .done, started: t0, ended: now.addingTimeInterval(-Inbox.keep))
        let old = transfer("old", state: .failed("x"), started: t0, ended: now.addingTimeInterval(-Inbox.keep - 1))
        let fresh = ClipEvent(deviceIds: ["a"], computer: "a", sent: true, preview: "x", at: now.addingTimeInterval(-60))
        var stale = fresh
        stale.at = now.addingTimeInterval(-Inbox.keep - 1)
        let items = Inbox.items(devices: [], herdr: [:], media: [:], approval: nil, transfers: [run, done, old], clip: fresh,
                                now: now, playedAt: [:])
        XCTAssertEqual(items.map { $0.key }, ["clip", "transfer|\(run.id.uuidString)", "transfer|\(done.id.uuidString)"])
        let gone = Inbox.items(devices: [], herdr: [:], media: [:], approval: nil, transfers: [old], clip: stale,
                               now: now, playedAt: [:])
        XCTAssertTrue(gone.isEmpty)
    }

    func testAPausedPlayerLeavesAfterTheKeepTime() {
        let now = Date(timeIntervalSince1970: 10 * Inbox.keep)
        let a = device("a")
        let b = device("b")
        let playing = ["a": media(player("Spotify", title: "Song", playing: true)), "b": media(player("mpv", title: "x"))]
        let paused = ["a": media(player("Spotify", title: "Song"))]
        let played = Inbox.notePlaying([:], devices: [a, b], media: playing, now: now)
        XCTAssertEqual(played, ["a": now], "only a player that plays gets a time")
        XCTAssertEqual(Inbox.notePlaying(played, devices: [a], media: paused, now: now.addingTimeInterval(1)), played)
        func items(_ players: [String: RemoteMedia], at time: Date, _ playedAt: [String: Date]) -> [InboxItem] {
            Inbox.items(devices: [a], herdr: [:], media: players, approval: nil, transfers: [], clip: nil, now: time, playedAt: playedAt)
        }
        XCTAssertEqual(items(paused, at: now.addingTimeInterval(Inbox.keep), played).count, 1)
        XCTAssertTrue(items(paused, at: now.addingTimeInterval(Inbox.keep + 1), played).isEmpty)
        XCTAssertTrue(items(paused, at: now, [:]).isEmpty, "a paused player that did not play here is not news")
        XCTAssertEqual(items(playing, at: now, [:]).count, 1, "a player that plays always shows")
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
        let clip = ClipEvent(deviceIds: ["a", "b"], computer: "2 computers", sent: true, preview: "x", at: t0)
        let items = inbox(devices, herdr: ["a": agents([blocked]), "b": agents([done])], clip: clip)
        XCTAssertEqual(Inbox.inScope(items, scope: nil).count, 4)
        XCTAssertEqual(Inbox.inScope(items, scope: "b").map { $0.kind }, [.pairRequest, .clipboard, .agentDone])
    }

    func testASwipeMovesTheMasterToTheEndAndATapPromotes() {
        let items = inbox([device("a")], herdr: ["a": agents([blocked, done, working])])
        let keys = items.map { $0.key }
        var a = InboxArrangement().sync(items)
        XCTAssertEqual(a.arrange(items).map { $0.key }, keys)

        a = a.swipe(keys[0])
        XCTAssertEqual(a.arrange(items).map { $0.key }, [keys[1], keys[2], keys[0]])

        a = a.promote(keys[0])
        XCTAssertEqual(a.arrange(items).map { $0.key }, [keys[0], keys[1], keys[2]])

        a = a.promote(keys[2])
        XCTAssertEqual(a.arrange(items).map { $0.key }, [keys[2], keys[0], keys[1]])

        // A swipe on the pinned master removes the pin.
        a = a.swipe(keys[2])
        XCTAssertNil(a.pinned)
        XCTAssertEqual(a.arrange(items).map { $0.key }, [keys[0], keys[1], keys[2]])
    }

    func testANewItemThatNeedsTheUserTakesTheMasterBack() {
        let before = inbox([device("a")], herdr: ["a": agents([done, working])])
        var a = InboxArrangement().sync(before).promote(before[1].key)
        XCTAssertEqual(a.arrange(before).first?.key, before[1].key)

        // The same items keep the pin.
        a = a.sync(before)
        XCTAssertEqual(a.pinned, before[1].key)

        let after = inbox([device("a")], herdr: ["a": agents([done, working, blocked])])
        a = a.sync(after)
        XCTAssertNil(a.pinned)
        XCTAssertEqual(a.arrange(after).first?.kind, .agentInput)
    }

    func testTheFirstSyncKeepsARestoredPin() {
        let items = inbox([device("a")], herdr: ["a": agents([blocked, done])])
        let a = InboxArrangement(pinned: items[1].key).sync(items)
        XCTAssertEqual(a.pinned, items[1].key)
    }

    func testSyncForgetsTheKeysThatAreGone() {
        let items = inbox([device("a")], herdr: ["a": agents([blocked, done])])
        let a = InboxArrangement(pinned: "gone", deferred: ["gone", items[0].key]).sync(items)
        XCTAssertNil(a.pinned)
        XCTAssertEqual(a.deferred, [items[0].key])
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

    func testTheFeedKeepsRunningTransfersAndTheNewestFinishedOnes() {
        // Newest first, as ShareModel keeps them. f2 failed.
        let finished = (1...5).reversed().map { i in
            transfer("f\(i)", state: i == 2 ? .failed("x") : .done, started: Date(timeIntervalSince1970: Double(i)))
        }
        XCTAssertEqual(Inbox.recentTransfers(finished, limit: 3).map { $0.name }, ["f5", "f4", "f3"])
        let running = (6...9).reversed().map { i in
            transfer("f\(i)", incoming: false, started: Date(timeIntervalSince1970: Double(i)))
        }
        XCTAssertEqual(Inbox.recentTransfers(running + finished, limit: 3).map { $0.name }, ["f9", "f8", "f7", "f6"],
                       "running transfers stay above the limit")
        XCTAssertEqual(Inbox.recentTransfers([running[0]] + finished, limit: 3).map { $0.name }, ["f9", "f5", "f4"])
        XCTAssertEqual(Inbox.recentTransfers(finished).count, 4, "the Inbox keeps 4 transfers")
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
        let item = InboxItem(.clip(c), computer: "desk")
        XCTAssertEqual(item.stackTitle, "Hidden text")
        XCTAssertEqual(item.masterTitle, "Sent to desk")

        let direct = ClipEvent(deviceIds: ["a"], computer: "desk", sent: true, preview: "s3cret", secret: true)
        XCTAssertEqual(direct.preview, "Hidden text", "the init drops the text of a secret")
        XCTAssertEqual(InboxItem(.clip(direct), computer: "desk").stackTitle, "Hidden text")

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
        XCTAssertEqual(input.stackTitle, "Migrate")
        XCTAssertEqual(input.stackLine, "desk")
        XCTAssertEqual(input.masterTitle, "Migrate")

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
        XCTAssertEqual(works.stackTitle, "w1:p1", "without a title and a project, the pane names the agent")

        let approve = InboxItem(.approval(approval("a")), computer: "name-a")
        XCTAssertEqual(approve.kind, .approval)
        XCTAssertEqual(approve.key, "approve|a|r1")
        XCTAssertEqual(approve.deviceIds, ["a"])
        XCTAssertEqual(approve.stateWord, "Needs approval")
        XCTAssertEqual(approve.tone, .red)
        XCTAssertEqual(approve.sourceParts, ["sudo"])
        XCTAssertEqual(approve.stackTitle, "Approve sudo")
        XCTAssertEqual(approve.stackLine, "user on host")
        XCTAssertEqual(approve.masterTitle, "Approve sudo on host?")
        var enrollRequest = approval("a")
        enrollRequest.kind = .enroll
        let enroll = InboxItem(.approval(enrollRequest), computer: "name-a")
        XCTAssertEqual(enroll.stackTitle, "Enroll \(noun)")
        XCTAssertEqual(enroll.masterTitle, "Enroll \(noun) on host?")

        let pair = InboxItem(.pair(deviceId: "new"), computer: "name-new")
        XCTAssertEqual(pair.kind, .pairRequest)
        XCTAssertEqual(pair.key, "pair|new")
        XCTAssertTrue(pair.deviceIds.isEmpty, "a pair request shows in every scope")
        XCTAssertEqual(pair.stateWord, "Pair request")
        XCTAssertEqual(pair.tone, .red)
        XCTAssertEqual(pair.sourceParts, [])
        XCTAssertEqual(pair.stackTitle, "name-new")
        XCTAssertEqual(pair.stackLine, "Compare the key to pair")
        XCTAssertEqual(pair.masterTitle, "name-new")

        let incoming = transfer("f.pdf", started: t0)
        let receiving = InboxItem(.transfer(incoming), computer: "desk")
        XCTAssertEqual(receiving.kind, .transfer)
        XCTAssertEqual(receiving.key, "transfer|\(incoming.id.uuidString)")
        XCTAssertEqual(receiving.deviceIds, ["a"])
        XCTAssertEqual(receiving.stateWord, "Receiving")
        XCTAssertEqual(receiving.tone, .accent)
        XCTAssertEqual(receiving.sourceParts, [])
        XCTAssertEqual(receiving.stackTitle, "f.pdf")
        XCTAssertEqual(receiving.stackLine, "From desk")
        XCTAssertEqual(receiving.masterTitle, "f.pdf")
        let sending = InboxItem(.transfer(transfer("g.png", incoming: false, started: t0)), computer: "desk")
        XCTAssertEqual(sending.stateWord, "Sending")
        XCTAssertEqual(sending.stackLine, "To desk")
        let received = InboxItem(.transfer(transfer("f.pdf", state: .done, started: t0, ended: t0)), computer: "desk")
        XCTAssertEqual(received.stateWord, "Received")
        XCTAssertEqual(received.tone, .green)
        let sent = InboxItem(.transfer(transfer("g.png", incoming: false, state: .done, started: t0, ended: t0)), computer: "desk")
        XCTAssertEqual(sent.stateWord, "Sent")
        let failed = InboxItem(.transfer(transfer("f.pdf", state: .failed("x"), started: t0, ended: t0)), computer: "desk")
        XCTAssertEqual(failed.stateWord, "Failed")
        XCTAssertEqual(failed.tone, .red)

        let text = InboxItem(.clip(ClipEvent(deviceIds: ["a"], computer: "desk", sent: true, preview: "hello", at: t0)), computer: "desk")
        XCTAssertEqual(text.kind, .clipboard)
        XCTAssertEqual(text.key, "clip")
        XCTAssertEqual(text.deviceIds, ["a"])
        XCTAssertEqual(text.stateWord, "Clipboard")
        XCTAssertEqual(text.tone, .cyan)
        XCTAssertEqual(text.sourceParts, [])
        XCTAssertEqual(text.stackTitle, "hello")
        XCTAssertEqual(text.stackLine, "Sent to desk")
        XCTAssertEqual(text.masterTitle, "Sent to desk")
        let image = InboxItem(.clip(ClipEvent.received(from: "a", computer: "desk", text: nil, at: t0)), computer: "desk")
        XCTAssertEqual(image.stackTitle, "An image")
        XCTAssertEqual(image.stackLine, "From desk")
        XCTAssertEqual(image.masterTitle, "From desk")

        let plays = InboxItem(.media(deviceId: "a", player: player("Spotify", title: "Song", artist: "Artist", playing: true)), computer: "desk")
        XCTAssertEqual(plays.kind, .media)
        XCTAssertEqual(plays.key, "media|a")
        XCTAssertEqual(plays.deviceIds, ["a"])
        XCTAssertEqual(plays.stateWord, "Playing")
        XCTAssertEqual(plays.tone, .green)
        XCTAssertEqual(plays.sourceParts, ["Spotify"])
        XCTAssertEqual(plays.stackTitle, "Song")
        XCTAssertEqual(plays.stackLine, "Artist · desk")
        XCTAssertEqual(plays.masterTitle, "Song")
        let paused = InboxItem(.media(deviceId: "a", player: player("mpv")), computer: "desk")
        XCTAssertEqual(paused.stateWord, "Paused")
        XCTAssertEqual(paused.tone, .sub)
        XCTAssertEqual(paused.stackTitle, "Unknown title")
        XCTAssertEqual(paused.stackLine, "desk")
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
