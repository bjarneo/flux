package org.omarchy.flux.core

import org.junit.Assert.assertEquals
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

    private fun inbox(devices: List<DeviceUi>, approval: ApproveRequest? = null) = inboxItems(devices, approval)

    private val working = HerdrAgent("w1:p1", "claude", AgentStatus.Working, "Refactor")
    private val blocked = HerdrAgent("w2:p1", "codex", AgentStatus.Blocked, "Migrate")
    private val done = HerdrAgent("w3:p1", "claude", AgentStatus.Done, "Fix test")
    private val idle = HerdrAgent("w3:p2", "pi", AgentStatus.Idle)

    @Test
    fun theItemsAreTheAgentsTheApprovalAndThePairRequests() {
        val devices = listOf(
            device("a", agents = listOf(working, blocked, done, idle), player = PlayerState("Spotify", title = "Song", playing = true)),
            device("new", paired = false, pairState = PairState.Incoming),
        )
        val items = inbox(devices, approval("a"))
        assertEquals(
            listOf(InboxKind.AgentWorking, InboxKind.AgentInput, InboxKind.AgentDone, InboxKind.PairRequest, InboxKind.Approval),
            items.map { it.kind },
        )
        assertEquals("an idle agent is not news", 0, items.count { it is AgentItem && it.agent.status == AgentStatus.Idle })
        assertEquals(3, items.needsYou())
    }

    @Test
    fun aComputerThatIsNotReachableAddsNoAgents() {
        val d = device("a", online = false, agents = listOf(blocked))
        assertTrue(inbox(listOf(d)).isEmpty())
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
        val items = inbox(devices)
        assertEquals(3, items.inScope(null).size)
        assertEquals(listOf(InboxKind.AgentDone, InboxKind.PairRequest), items.inScope("b").map { it.kind })
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
    fun thePlusKeyStartsOnTheSelectedComputer() {
        val a = device("a", agents = listOf(working))
        val b = device("b")
        val off = device("off", online = false)
        // The selected computer is the target, also when it has no Agent control. Its page shows the reason.
        assertEquals(Target.One(b), newAgentTarget("b", listOf(a, b)))
        assertEquals(Target.One(a), newAgentTarget("a", listOf(a, b)))
        assertEquals(Target.None(off), newAgentTarget("off", listOf(a, off)))
        // With all computers in scope, the user picks from each online computer.
        assertEquals(Target.Ask(listOf(a, b)), newAgentTarget(null, listOf(a, b, off)))
        assertEquals(Target.None(null), newAgentTarget(null, listOf(off)))
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
    fun theFeedNamesTheComputersOfAClip() {
        InboxFeed.clipSent(listOf("a" to "desk", "b" to "laptop"), "hello\nworld")
        val c = InboxFeed.clip.value!!
        assertEquals("2 computers", c.computer)
        assertEquals("hello world", c.preview)
        assertTrue(c.sent)
        SendLog.replace(emptyList())
        InboxFeed.clipReceived("a", "desk", null)
        assertTrue(InboxFeed.clip.value!!.image)
        assertEquals("desk", InboxFeed.clip.value!!.computer)
        val logged = SendLog.entries.value.single()
        assertEquals("a clip from a computer goes to the chat", SendKind.ClipImage, logged.kind)
        assertTrue(logged.incoming)
        SendLog.replace(emptyList())
    }
}
