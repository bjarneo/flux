package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class ChatListTest {
    private fun device(
        id: String,
        name: String,
        paired: Boolean = true,
        online: Boolean = true,
        agents: List<HerdrAgent> = emptyList(),
        since: Map<String, Long> = emptyMap(),
        pairState: PairState = if (paired) PairState.Paired else PairState.None,
        lastSeen: Long = 0,
    ) = DeviceUi(
        id = id, name = name, type = "laptop", ip = "", paired = paired, online = online,
        pairState = pairState, pairKey = "", pairOutgoing = false,
        battery = null, charging = false, players = emptyList(), player = null,
        commands = emptyList(), commandsLoaded = false,
        herdr = if (agents.isEmpty()) null else HerdrState(enabled = true, running = true, agents = agents, control = true),
        agentSince = since,
        lastSeen = lastSeen,
    )

    private val migrate = HerdrAgent("w2:p1", "codex", AgentStatus.Blocked, "Run the database migration", "billing")
    private val refactor = HerdrAgent("w1:p1", "claude", AgentStatus.Working, "Refactor the sync loop", "flux")
    private val flaky = HerdrAgent("w3:p1", "claude", AgentStatus.Done, "Fix the flaky login test", "web")
    private val idle = HerdrAgent("w3:p2", "pi", AgentStatus.Idle, "", "web")

    private fun entry(id: Long, device: String, text: String, at: Long, kind: SendKind = SendKind.Text) =
        SendEntry(id, device, device, kind, text, at = at)

    private fun approval(computer: String, time: Long = 0) = ApproveRequest(
        computerId = computer, computerName = computer, id = "r1", kind = ApproveRequest.Kind.Approve,
        host = computer, user = "dev", service = "sudo", tty = "pts/3", rhost = "", time = time, nonce = "", timeoutSeconds = 30,
    )

    @Test
    fun theAgentsThatWaitAndTheApprovalAreOnTop() {
        val pc = device(
            "pc", "omarchy-xps",
            agents = listOf(refactor, migrate, flaky, idle),
            since = mapOf("w2:p1" to 5_000L, "w1:p1" to 100L, "w3:p1" to 200L),
        )
        val list = chatList(listOf(pc), approval("pc", time = 1), emptyList(), SeenClock(), now = 9_000)
        assertEquals("the newest first", listOf("agent|pc|w2:p1", "approve|pc|r1"), list.needs.map { it.key })
        assertEquals("an approval takes the time of its request", 1_000L, list.needs.last().at)
        assertEquals("the agents that work come first, then the agents that are done", listOf("w1:p1", "w3:p1", "w3:p2"), list.agents.map { it.agent.pane })
        assertEquals(2, list.needsYou)
    }

    @Test
    fun theBadgeCountsTheBlockedAgentOfAComputerThatIsNotReachable() {
        val pc = device("pc", "omarchy-xps", agents = listOf(migrate))
        val desk = device("desk", "omarchy-desk", online = false, agents = listOf(migrate.copy(pane = "w9:p1")), lastSeen = 1L)
        val devices = listOf(pc, desk)
        assertEquals(3, needsYouCount(devices, approval("pc")))
        assertEquals(chatList(devices, approval("pc"), emptyList(), SeenClock(), 0L).needsYou, needsYouCount(devices, approval("pc")))
    }

    @Test
    fun anAgentWithNoStartTakesTheTimeThatTheListSawIt() {
        val clock = SeenClock()
        val pc = device("pc", "omarchy-xps", agents = listOf(flaky))
        assertEquals(10L, chatList(listOf(pc), null, emptyList(), clock, now = 10).agents.single().at)
        assertEquals(10L, chatList(listOf(pc), null, emptyList(), clock, now = 99).agents.single().at)
        val working = pc.copy(herdr = pc.herdr!!.copy(agents = listOf(flaky.copy(status = AgentStatus.Working))))
        assertEquals("a new status is new", 120L, chatList(listOf(working), null, emptyList(), clock, now = 120).agents.single().at)
    }

    @Test
    fun aComputerThatIsNotReachableKeepsItsLastKnownAgentsInTheirGroups() {
        val desk = device("desk", "omarchy-desk", online = false, agents = listOf(migrate, flaky), lastSeen = 4_000L)
        val pc = device("pc", "omarchy-xps", agents = listOf(refactor))
        val list = chatList(listOf(desk, pc), null, emptyList(), SeenClock(), now = 9_000)
        assertEquals("a blocked agent stays in Needs you", listOf("agent|desk|w2:p1"), list.needs.map { it.key })
        assertEquals(listOf("w1:p1", "w3:p1"), list.agents.map { it.agent.pane })
        val blocked = list.needs.single() as AgentRow
        assertEquals(false, blocked.reachable)
        assertEquals(4_000L, blocked.since)
        val done = list.agents.single { it.agent.pane == "w3:p1" }
        assertEquals("the agent keeps its group", AgentStatus.Done, done.agent.status)
        assertEquals(false, done.reachable)
        val works = list.agents.single { it.agent.pane == "w1:p1" }
        assertEquals(true, works.reachable)
        assertEquals(0L, works.since)
        assertEquals(listOf("pc", "desk"), list.computers.map { it.device.id })
    }

    @Test
    fun aComputerThatIsNotReachableAndHasNoAgentListAddsNoAgents() {
        val desk = device("desk", "omarchy-desk", online = false)
        val list = chatList(listOf(desk), null, emptyList(), SeenClock(), now = 1)
        assertTrue(list.needs.isEmpty())
        assertTrue(list.agents.isEmpty())
        assertEquals(listOf("desk"), list.computers.map { it.device.id })
    }

    @Test
    fun eachComputerShowsItsNewestEntryAndTheOnlineComputersComeFirst() {
        val pc = device("pc", "omarchy-xps")
        val desk = device("desk", "omarchy-desk", online = false)
        val other = device("other", "work-thinkpad")
        val log = listOf(entry(1, "pc", "Dinner at 7", 100), entry(2, "pc", "invoice.pdf", 50, SendKind.File), entry(3, "desk", "notes", 900))
        val list = chatList(listOf(desk, other, pc), null, log, SeenClock(), now = 1_000)
        assertEquals(listOf("pc", "other", "desk"), list.computers.map { it.device.id })
        assertEquals("Dinner at 7", list.computers.first().last?.text)
        assertEquals(null, list.computers[1].last)
    }

    @Test
    fun aPairRequestNeedsTheUserAndAnApprovalOfAnotherComputerDoesNotShow() {
        val pc = device("pc", "omarchy-xps")
        val new = device("new", "framework-13", paired = false, pairState = PairState.Incoming)
        val list = chatList(listOf(pc, new), approval("gone"), emptyList(), SeenClock(), now = 1)
        assertEquals(listOf("pair|new"), list.needs.map { it.key })
        assertEquals(listOf("pc"), list.computers.map { it.device.id })
    }

    @Test
    fun theSearchKeepsTheRowsThatHoldItAndShowsTheEntryThatMatches() {
        val pc = device("pc", "omarchy-xps", agents = listOf(migrate, flaky))
        val desk = device("desk", "omarchy-desk")
        val log = listOf(entry(1, "pc", "invoice-0042.pdf", 10, SendKind.File), entry(2, "pc", "Dinner at 7", 20), entry(3, "desk", "notes", 30))
        val byFile = chatList(listOf(pc, desk), null, log, SeenClock(), now = 100, query = "INVOICE")
        assertTrue(byFile.needs.isEmpty())
        assertTrue(byFile.agents.isEmpty())
        assertEquals(listOf("pc"), byFile.computers.map { it.device.id })
        assertEquals("invoice-0042.pdf", byFile.computers.single().last?.text)
        val byProject = chatList(listOf(pc, desk), null, log, SeenClock(), now = 100, query = "billing")
        assertEquals(listOf("agent|pc|w2:p1"), byProject.needs.map { it.key })
        val byName = chatList(listOf(pc, desk), null, log, SeenClock(), now = 100, query = "desk")
        assertEquals("a computer that matches by name shows its newest entry", "notes", byName.computers.single().last?.text)
    }

    @Test
    fun aScopeKeepsOnlyTheRowsOfOneComputer() {
        val pc = device("pc", "omarchy-xps", agents = listOf(migrate, refactor))
        val desk = device("desk", "omarchy-desk", agents = listOf(flaky))
        val ask = device("new", "framework-13", paired = false, pairState = PairState.Incoming)
        val list = chatList(listOf(pc, desk, ask), approval("desk"), emptyList(), SeenClock(), now = 9_000)
        assertEquals("no scope keeps all rows", list, list.inScope(null))

        val xps = list.inScope("pc")
        assertEquals(setOf("agent|pc|w2:p1", "pair|new"), xps.needs.map { it.key }.toSet())
        assertEquals(listOf("w1:p1"), xps.agents.map { it.agent.pane })
        assertEquals(listOf("pc"), xps.computers.map { it.device.id })

        val other = list.inScope("desk")
        assertEquals("the approval of the computer and the pair request stay", setOf("approve|desk|r1", "pair|new"), other.needs.map { it.key }.toSet())
        assertEquals(listOf("w3:p1"), other.agents.map { it.agent.pane })
        assertTrue(list.inScope("gone").agents.isEmpty())
    }
}
