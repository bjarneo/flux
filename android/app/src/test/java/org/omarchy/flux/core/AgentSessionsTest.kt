package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Test

class AgentSessionsTest {
    private fun agent(pane: String, session: String, status: AgentStatus = AgentStatus.Idle) =
        HerdrAgent(pane = pane, agent = "claude", status = status, project = "p", session = session)

    private fun device(id: String, sessions: List<HerdrSessionInfo>, agents: List<HerdrAgent>) =
        DeviceUi(
            id = id, name = id, type = "laptop", ip = "", paired = true, online = true,
            pairState = PairState.Paired, pairKey = "", pairOutgoing = false,
            battery = null, charging = false, players = emptyList(), player = null,
            commands = emptyList(), commandsLoaded = false,
            herdr = HerdrState(true, true, agents, sessions = sessions),
        )

    private val two = listOf(HerdrSessionInfo("default", default = true, running = true), HerdrSessionInfo("work", running = true))

    private fun rows(d: DeviceUi) = d.herdr!!.agents.map { AgentRow(d.id, d.name, it, false, 0L) }

    @Test
    fun oneSessionKeepsAllAgents() {
        val d = device("pc", listOf(HerdrSessionInfo("default", default = true, running = true)), listOf(agent("1", "default"), agent("2", "other")))
        assertEquals(emptyList<DeviceUi>(), stripComputers(listOf(d)))
        assertEquals(2, agentsOfPickedSessions(rows(d), listOf(d)) { null }.size)
    }

    @Test
    fun manySessionsKeepTheAgentsOfThePickedSession() {
        val d = device("pc", two, listOf(agent("1", "default"), agent("2", "work")))
        assertEquals(listOf(d), stripComputers(listOf(d)))
        assertEquals(listOf("1"), agentsOfPickedSessions(rows(d), listOf(d)) { null }.map { it.agent.pane })
        assertEquals(listOf("2"), agentsOfPickedSessions(rows(d), listOf(d)) { "work" }.map { it.agent.pane })
        assertEquals("a session that is gone gives the default session", listOf("1"), agentsOfPickedSessions(rows(d), listOf(d)) { "gone" }.map { it.agent.pane })
    }

    @Test
    fun theFilterWorksForEachComputer() {
        val a = device("a", two, listOf(agent("1", "default"), agent("2", "work")))
        val b = device("b", listOf(HerdrSessionInfo("default", default = true, running = true)), listOf(agent("3", "default")))
        val all = rows(a) + rows(b)
        assertEquals(listOf("2", "3"), agentsOfPickedSessions(all, listOf(a, b)) { if (it == "a") "work" else null }.map { it.agent.pane })
    }

    @Test
    fun needsYouKeepsTheBlockedAgentsOfAllSessions() {
        val d = device("pc", two, listOf(agent("1", "default"), agent("2", "work", AgentStatus.Blocked)))
        val list = chatList(listOf(d), null, emptyList(), SeenClock(), 1_000L)
        assertEquals(listOf("2"), list.needs.filterIsInstance<AgentRow>().map { it.agent.pane })
        assertEquals(listOf("1"), agentsOfPickedSessions(list.agents, listOf(d)) { null }.map { it.agent.pane })
    }
}
