package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class InboxModelTest {
    private fun device(
        id: String,
        paired: Boolean = true,
        online: Boolean = true,
        pairState: PairState = if (paired) PairState.Paired else PairState.None,
        agents: List<HerdrAgent> = emptyList(),
        player: PlayerState? = null,
        input: Boolean = false,
    ) = DeviceUi(
        id = id, name = "name-$id", type = "laptop", ip = "", paired = paired, online = online,
        pairState = pairState, pairKey = "", pairOutgoing = false, battery = null, charging = false,
        players = emptyList(), player = player, commands = emptyList(), commandsLoaded = false,
        herdrSupported = agents.isNotEmpty(),
        herdr = if (agents.isEmpty()) null else HerdrState(enabled = true, running = true, agents = agents, control = true),
        inputSupported = input,
    )

    private fun approval(computer: String) = ApproveRequest(
        computerId = computer, computerName = "name-$computer", id = "r1", kind = ApproveRequest.Kind.Approve,
        host = "host", user = "user", service = "sudo", tty = "pts/1", rhost = "", time = 0, nonce = "0".repeat(64), timeoutSeconds = 60,
    )

    /** The items at the time 0, with every player seen at the time 0. */
    private fun inbox(
        devices: List<DeviceUi>,
        approval: ApproveRequest? = null,
        transfers: List<Transfer> = emptyList(),
        clip: ClipEvent? = null,
    ) = inboxItems(devices, approval, transfers, clip, now = 0, playedAt = devices.associate { it.id to 0L })

    private val working = HerdrAgent("w1:p1", "claude", AgentStatus.Working, "Refactor")
    private val blocked = HerdrAgent("w2:p1", "codex", AgentStatus.Blocked, "Migrate")
    private val done = HerdrAgent("w3:p1", "claude", AgentStatus.Done, "Fix test")
    private val idle = HerdrAgent("w3:p2", "pi", AgentStatus.Idle)

    @Test
    fun whatNeedsTheUserComesFirst() {
        val devices = listOf(
            device("a", agents = listOf(working, blocked, done, idle), player = PlayerState("Spotify", title = "Song", playing = true)),
            device("new", paired = false, pairState = PairState.Incoming),
        )
        val clip = ClipEvent(listOf("a"), "name-a", sent = true, preview = "text")
        val transfer = Transfer(1, "a", "name-a", "f.pdf", incoming = true)
        val items = inbox(devices, approval("a"), listOf(transfer), clip)
        assertEquals(
            "what needs the user, then what plays, the clip, and the transfers, then the agents that do not wait",
            listOf(
                InboxKind.AgentInput, InboxKind.Approval, InboxKind.PairRequest, InboxKind.Media,
                InboxKind.Clipboard, InboxKind.Transfer, InboxKind.AgentDone, InboxKind.AgentWorking,
            ),
            items.map { it.kind },
        )
        assertEquals("an idle agent is not news", 0, items.count { it is AgentItem && it.agent.status == AgentStatus.Idle })
        assertEquals(3, items.needsYou())
    }

    @Test
    fun aComputerThatIsNotReachableAddsNoAgentsAndNoPlayer() {
        val d = device("a", online = false, agents = listOf(blocked), player = PlayerState("mpv", title = "x", playing = true))
        assertTrue(inbox(listOf(d), null, emptyList(), null).isEmpty())
    }

    @Test
    fun runningTransfersComeFirstThenTheNewest() {
        val old = Transfer(1, "a", "a", "old", incoming = true, state = TransferState.Done, at = 10)
        val new = Transfer(2, "a", "a", "new", incoming = true, state = TransferState.Failed, at = 20)
        val run = Transfer(3, "a", "a", "run", incoming = false, at = 5)
        val names = inbox(emptyList(), null, listOf(old, new, run), null).map { (it as TransferItem).transfer.name }
        assertEquals(listOf("run", "new", "old"), names)
    }

    @Test
    fun aPlayingPlayerComesBeforeAPausedOne() {
        val paused = device("a", player = PlayerState("mpv", title = "Paused song"))
        val playing = device("b", player = PlayerState("Spotify", title = "Song", playing = true))
        val empty = device("c", player = PlayerState("Firefox"))
        val ids = inbox(listOf(paused, playing, empty), null, emptyList(), null).map { (it as MediaItem).deviceId }
        assertEquals("a paused player without a title is not news", listOf("b", "a"), ids)
    }

    @Test
    fun finishedTransfersAndTheClipLeaveAfterTheKeepTime() {
        val now = 10 * INBOX_KEEP_MS
        val run = Transfer(1, "a", "a", "run", incoming = true, at = 0)
        val done = Transfer(2, "a", "a", "done", incoming = true, state = TransferState.Done, at = 0, ended = now - INBOX_KEEP_MS)
        val old = Transfer(3, "a", "a", "old", incoming = true, state = TransferState.Failed, at = 0, ended = now - INBOX_KEEP_MS - 1)
        val fresh = ClipEvent(listOf("a"), "a", sent = true, preview = "x", at = now - 60_000)
        val stale = fresh.copy(at = now - INBOX_KEEP_MS - 1)
        val items = inboxItems(emptyList(), null, listOf(run, done, old), fresh, now, emptyMap())
        assertEquals(listOf("clip", "transfer|1", "transfer|2"), items.map { it.key })
        assertTrue(inboxItems(emptyList(), null, listOf(old), stale, now, emptyMap()).isEmpty())
    }

    @Test
    fun aPausedPlayerLeavesAfterTheKeepTime() {
        val now = 10 * INBOX_KEEP_MS
        val playing = device("a", player = PlayerState("Spotify", title = "Song", playing = true))
        val paused = device("a", player = PlayerState("Spotify", title = "Song"))
        val played = notePlaying(emptyMap(), listOf(playing, device("b", player = PlayerState("mpv", title = "x"))), now)
        assertEquals("only a player that plays gets a time", mapOf("a" to now), played)
        assertEquals(played, notePlaying(played, listOf(paused), now + 1))
        assertEquals(1, inboxItems(listOf(paused), null, emptyList(), null, now + INBOX_KEEP_MS, played).size)
        assertTrue(inboxItems(listOf(paused), null, emptyList(), null, now + INBOX_KEEP_MS + 1, played).isEmpty())
        assertTrue("a paused player that did not play here is not news", inboxItems(listOf(paused), null, emptyList(), null, now, emptyMap()).isEmpty())
        assertEquals("a player that plays always shows", 1, inboxItems(listOf(playing), null, emptyList(), null, now, emptyMap()).size)
    }

    @Test
    fun twoAgentsOnOnePaneMakeOneItem() {
        val twin = blocked.copy(agent = "claude")
        val items = inbox(listOf(device("a", agents = listOf(blocked, twin, done))))
        assertEquals(items.map { it.key }.distinct(), items.map { it.key })
        assertEquals(2, items.size)
        assertEquals("codex", (items.first() as AgentItem).agent.agent)
    }

    @Test
    fun theReachCountsThePairedComputersInScope() {
        val a = device("a")
        val off = device("off", online = false)
        val new = device("new", paired = false)
        assertEquals(InboxReach(1, listOf(off)), inboxReach(null, listOf(a, off, new)))
        assertTrue(inboxReach("off", listOf(a, off)).noneOnline)
        assertTrue(!inboxReach("a", listOf(a, off)).noneOnline)
        assertTrue("no paired computer is not the same as none online", !inboxReach(null, listOf(new)).noneOnline)
    }

    @Test
    fun theScopeKeepsItsComputerAndThePairRequests() {
        val devices = listOf(
            device("a", agents = listOf(blocked)),
            device("b", agents = listOf(done)),
            device("new", paired = false, pairState = PairState.Incoming),
        )
        val clip = ClipEvent(listOf("a", "b"), "2 computers", sent = true, preview = "x")
        val items = inbox(devices, null, emptyList(), clip)
        assertEquals(4, items.inScope(null).size)
        val b = items.inScope("b")
        assertEquals(listOf(InboxKind.PairRequest, InboxKind.Clipboard, InboxKind.AgentDone), b.map { it.kind })
    }

    @Test
    fun aSwipeMovesTheMasterToTheEndAndATapPromotes() {
        val items = inbox(listOf(device("a", agents = listOf(blocked, done, working))), null, emptyList(), null)
        val keys = items.map { it.key }
        var a = InboxArrangement().sync(items)
        assertEquals(keys, a.arrange(items).map { it.key })

        a = a.swipe(keys[0])
        assertEquals(listOf(keys[1], keys[2], keys[0]), a.arrange(items).map { it.key })

        a = a.promote(keys[0])
        assertEquals(listOf(keys[0], keys[1], keys[2]), a.arrange(items).map { it.key })

        a = a.promote(keys[2])
        assertEquals(listOf(keys[2], keys[0], keys[1]), a.arrange(items).map { it.key })

        // A swipe on the pinned master removes the pin.
        a = a.swipe(keys[2])
        assertNull(a.pinned)
        assertEquals(listOf(keys[0], keys[1], keys[2]), a.arrange(items).map { it.key })
    }

    @Test
    fun aNewItemThatNeedsTheUserTakesTheMasterBack() {
        val before = inbox(listOf(device("a", agents = listOf(done, working))), null, emptyList(), null)
        var a = InboxArrangement().sync(before).promote(before[1].key)
        assertEquals(before[1].key, a.arrange(before).first().key)

        // The same items keep the pin.
        a = a.sync(before)
        assertEquals(before[1].key, a.pinned)

        val after = inbox(listOf(device("a", agents = listOf(done, working, blocked))), null, emptyList(), null)
        a = a.sync(after)
        assertNull(a.pinned)
        assertEquals(InboxKind.AgentInput, a.arrange(after).first().kind)
    }

    @Test
    fun theFirstSyncKeepsARestoredPin() {
        val items = inbox(listOf(device("a", agents = listOf(blocked, done))), null, emptyList(), null)
        val a = InboxArrangement(pinned = items[1].key).sync(items)
        assertEquals(items[1].key, a.pinned)
    }

    @Test
    fun syncForgetsTheKeysThatAreGone() {
        val items = inbox(listOf(device("a", agents = listOf(blocked, done))), null, emptyList(), null)
        val a = InboxArrangement(pinned = "gone", deferred = listOf("gone", items[0].key)).sync(items)
        assertNull(a.pinned)
        assertEquals(listOf(items[0].key), a.deferred)
    }

    @Test
    fun aStatusChangeMakesANewItem() {
        val a = AgentItem("a", "a", blocked, control = true)
        val b = AgentItem("a", "a", blocked.copy(status = AgentStatus.Done), control = true)
        assertTrue(a.key != b.key)
    }

    @Test
    fun theTargetIsTheComputerInScopeOrTheOnlyOneOnline() {
        val a = device("a")
        val b = device("b", input = true)
        val off = device("off", online = false)
        assertEquals(Target.One(a), target("a", listOf(a, b)))
        assertEquals(Target.None(off), target("off", listOf(a, off)))
        assertEquals(Target.None(null), target("gone", listOf(a)))
        assertEquals(Target.Ask(listOf(a, b)), target(null, listOf(a, b, off)))
        assertEquals(Target.One(b), target(null, listOf(a, b)) { it.inputSupported })
        assertEquals(Target.None(a), target("a", listOf(a, b)) { it.inputSupported })
        assertEquals(Target.None(null), target(null, listOf(off)))
        assertEquals(Target.One(a), target(null, listOf(a, off)))
        assertTrue(hasFeature(null, listOf(a, b)) { it.inputSupported })
        assertTrue(!hasFeature("a", listOf(a, b)) { it.inputSupported })
    }

    @Test
    fun thePromptIsTheTextAboveTheChoices() {
        val lines = listOf(
            "● I added the migration.",
            "─".repeat(40),
            " Bash command",
            "",
            "   bin/migrate --apply",
            "   Apply the pending migration",
            "",
            " Do you want to proceed?",
            " ❯ 1. Yes",
            "   2. Yes, and do not ask again",
            "   3. No",
        )
        assertEquals("Bash command\nbin/migrate --apply\nApply the pending migration\nDo you want to proceed?", agentPrompt(lines))
        assertEquals("Apply the pending migration\nDo you want to proceed?", agentPrompt(lines, maxLines = 2))
        // A short prompt drops the question, so that the command stays next to the choices.
        assertEquals("Bash command\nbin/migrate --apply\nApply the pending migration", agentPrompt(lines, maxLines = 3, dropAsk = true))
        assertEquals("bin/migrate --apply\nApply the pending migration", agentPrompt(lines, maxLines = 2, dropAsk = true))
    }

    @Test
    fun aShortPromptKeepsALastLineThatIsNotAQuestion() {
        val lines = listOf("Would you like to run the following command?", "", "$ bin/migrate --apply", "", "› 1. Yes, proceed (y)", "  2. No (esc)")
        assertEquals("Would you like to run the following command?\n$ bin/migrate --apply", agentPrompt(lines, maxLines = 3, dropAsk = true))
        // Without choices, nothing answers the question, so it stays.
        assertEquals("Which file?", agentPrompt(listOf("Some work", "────", "", "Which file?", ""), maxLines = 3, dropAsk = true))
    }

    @Test
    fun withoutChoicesThePromptIsTheLastLines() {
        assertEquals("Which file?", agentPrompt(listOf("Some work", "────", "", "Which file?", "")))
        assertEquals("", agentPrompt(emptyList()))
    }

    @Test
    fun aClipPreviewIsOneShortLine() {
        assertEquals("a b c", clipPreview("  a\n\tb   c \n"))
        val long = clipPreview("x".repeat(500), max = 10)
        assertEquals(10, long.length)
        assertTrue(long.endsWith("…"))
    }

    @Test
    fun theFeedKeepsRunningTransfersAndTheNewestFinishedOnes() {
        var list = emptyList<Transfer>()
        for (i in 1L..5L) list = endTransfer(startTransfer(list, Transfer(i, "a", "a", "f$i", incoming = true), max = 3), i, ok = i != 2L, at = i)
        assertEquals(listOf(5L, 4L, 3L), list.map { it.id })
        list = startTransfer(list, Transfer(6, "a", "a", "f6", incoming = false), max = 3)
        list = startTransfer(list, Transfer(7, "a", "a", "f7", incoming = false), max = 3)
        list = startTransfer(list, Transfer(8, "a", "a", "f8", incoming = false), max = 3)
        list = startTransfer(list, Transfer(9, "a", "a", "f9", incoming = false), max = 3)
        assertEquals("running transfers stay above the limit", listOf(9L, 8L, 7L, 6L), list.map { it.id })
        assertEquals(TransferState.Failed, endTransfer(list, 9, ok = false, at = 9).first().state)
        assertEquals("an ended transfer does not change again", TransferState.Done, endTransfer(endTransfer(list, 9, true, 9), 9, false, 10).first().state)
    }

    @Test
    fun aFileThatTheComputerSendsAgainKeepsItsItem() {
        var list = endTransfer(startTransfer(emptyList(), Transfer(1, "a", "a", "f1", incoming = true, at = 5)), 1, ok = false, at = 7)
        list = resumeTransfer(list, 1)
        assertEquals(listOf(1L), list.map { it.id })
        assertEquals(TransferState.Running, list.single().state)
        assertEquals(0L, list.single().ended)
        assertEquals("the item keeps its start time", 5L, list.single().at)
        assertEquals(list, resumeTransfer(list, 2))

        val id = InboxFeed.transferStarted("a", "desk", "f.txt", incoming = true)
        InboxFeed.transferEnded(id, false)
        assertTrue(InboxFeed.transferResumed(id))
        assertEquals(TransferState.Running, InboxFeed.transfers.value.first { it.id == id }.state)
        assertFalse(InboxFeed.transferResumed(-1))
    }

    @Test
    fun theFeedNamesTheComputersOfAClip() {
        InboxFeed.clipSent(listOf("a" to "desk", "b" to "laptop"), "hello\nworld")
        val c = InboxFeed.clip.value!!
        assertEquals("2 computers", c.computer)
        assertEquals("hello world", c.preview)
        assertTrue(c.sent)
        InboxFeed.clipReceived("a", "desk", null)
        assertTrue(InboxFeed.clip.value!!.image)
        assertEquals("desk", InboxFeed.clip.value!!.computer)
    }
}
