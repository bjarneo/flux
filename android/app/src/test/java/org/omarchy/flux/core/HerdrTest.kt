package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.OUTGOING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types

class HerdrTest {
    private fun body(line: String) = Packet.parse("""{"id":1,"type":"flux.herdr","body":$line}""")!!.body

    private fun agent(pane: String, status: AgentStatus) = HerdrAgent(pane, "claude", status)

    @Test
    fun capabilities() {
        assertTrue(Types.FLUX_HERDR in INCOMING)
        assertTrue(Types.FLUX_HERDR in OUTGOING)
    }

    @Test
    fun parsesState() {
        val s = parseHerdrState(
            body(
                """{"kind":"state","enabled":true,"running":true,"agents":[
                {"pane":"w5:p1","agent":"claude","status":"working","title":"Custom skin loading","project":"cliamp","workspace":"cliamp","extra":1},
                {"pane":"w6:p1","agent":"codex","status":"thinking"},
                {"agent":"claude","status":"idle"}
                ]}""",
            ),
        )!!
        assertTrue(s.enabled)
        assertTrue(s.running)
        assertEquals("an agent without a pane is dropped", 2, s.agents.size)
        assertEquals(HerdrAgent("w5:p1", "claude", AgentStatus.Working, "Custom skin loading", "cliamp", "cliamp"), s.agents[0])
        assertEquals("an unknown status is unknown", AgentStatus.Unknown, s.agents[1].status)
        assertEquals("", s.agents[1].title)
    }

    @Test
    fun parsesStateThatIsOff() {
        val s = parseHerdrState(body("""{"kind":"state","enabled":false,"running":true}"""))!!
        assertFalse(s.enabled)
        assertFalse("a state that is off is not running", s.running)
        assertTrue(s.agents.isEmpty())
        assertNull("an output is not a state", parseHerdrState(body("""{"kind":"output","pane":"w1:p1"}""")))
    }

    @Test
    fun parsesOutput() {
        val o = parseHerdrOutput(body("""{"kind":"output","pane":"w5:p1","text":"a  \nb\n\n","truncated":true}"""))!!
        assertEquals("w5:p1", o.pane)
        assertEquals("a\nb", o.text)
        assertTrue(o.truncated)
        assertFalse(o.loading)
        assertNull(o.error)

        val e = parseHerdrOutput(body("""{"kind":"output","pane":"w5:p1","error":"The agent in w5:p1 is gone"}"""))!!
        assertEquals("The agent in w5:p1 is gone", e.error)
        assertEquals("", e.text)
        assertNull("an output needs a pane", parseHerdrOutput(body("""{"kind":"output","text":"x"}""")))
    }

    @Test
    fun tidiesRules() {
        val rule = "─".repeat(120)
        assertEquals("─".repeat(32) + "\n❯ 1. Yes", termLines("$rule\n❯ 1. Yes  \n  \n").joinToString("\n") { it.text })
        assertEquals("a short rule stays", "-----", termLines("-----").single().text)
    }

    @Test
    fun sortsBlockedFirstAndKeepsHerdrOrder() {
        val agents = listOf(
            agent("a", AgentStatus.Idle),
            agent("b", AgentStatus.Working),
            agent("c", AgentStatus.Blocked),
            agent("d", AgentStatus.Unknown),
            agent("e", AgentStatus.Done),
            agent("f", AgentStatus.Working),
            agent("g", AgentStatus.Blocked),
        )
        assertEquals(listOf("c", "g", "e", "b", "f", "a", "d"), sortAgents(agents).map { it.pane })
        assertEquals(2, HerdrState(true, true, agents).blocked)
    }

    @Test
    fun firstStateOnlySetsTheStart() {
        val t = HerdrTracker()
        val alerts = t.update(listOf(agent("a", AgentStatus.Blocked), agent("b", AgentStatus.Done), agent("c", AgentStatus.Working)))
        assertEquals("a working pane clears an old notification", listOf(AgentAlert.Clear("c")), alerts)
    }

    @Test
    fun blockedNeedsInput() {
        val t = HerdrTracker()
        t.update(listOf(agent("a", AgentStatus.Working), agent("b", AgentStatus.Idle)))
        val alerts = t.update(listOf(agent("a", AgentStatus.Blocked), agent("b", AgentStatus.Blocked)))
        assertEquals(listOf(AgentAlert.NeedsInput(agent("a", AgentStatus.Blocked)), AgentAlert.NeedsInput(agent("b", AgentStatus.Blocked))), alerts)
        assertTrue("the same status posts nothing", t.update(listOf(agent("a", AgentStatus.Blocked), agent("b", AgentStatus.Blocked))).isEmpty())
    }

    @Test
    fun newPaneThatIsBlockedPostsNothing() {
        val t = HerdrTracker()
        t.update(emptyList())
        assertTrue(t.update(listOf(agent("a", AgentStatus.Blocked))).isEmpty())
    }

    @Test
    fun workingToReadyFinishes() {
        val t = HerdrTracker()
        t.update(listOf(agent("a", AgentStatus.Working), agent("b", AgentStatus.Working), agent("c", AgentStatus.Idle)))
        val alerts = t.update(listOf(agent("a", AgentStatus.Done), agent("b", AgentStatus.Idle), agent("c", AgentStatus.Done)))
        assertEquals(
            "idle to done is not a finish",
            listOf(AgentAlert.Finished(agent("a", AgentStatus.Done)), AgentAlert.Finished(agent("b", AgentStatus.Idle)), AgentAlert.Clear("c")),
            alerts,
        )
    }

    @Test
    fun backToWorkingClears() {
        val t = HerdrTracker()
        t.update(listOf(agent("a", AgentStatus.Working)))
        t.update(listOf(agent("a", AgentStatus.Blocked)))
        assertEquals(listOf(AgentAlert.Clear("a")), t.update(listOf(agent("a", AgentStatus.Working))))
        t.update(listOf(agent("a", AgentStatus.Done)))
        assertEquals("a flap back to working cancels the finish", listOf(AgentAlert.Clear("a")), t.update(listOf(agent("a", AgentStatus.Working))))
    }

    @Test
    fun goneClears() {
        val t = HerdrTracker()
        t.update(listOf(agent("a", AgentStatus.Blocked), agent("b", AgentStatus.Working)))
        assertEquals(listOf(AgentAlert.Clear("a")), t.update(listOf(agent("b", AgentStatus.Working))))
    }

    @Test
    fun unknownKeepsTheLastStatus() {
        val t = HerdrTracker()
        t.update(listOf(agent("a", AgentStatus.Working)))
        assertTrue(t.update(listOf(agent("a", AgentStatus.Unknown))).isEmpty())
        assertEquals(listOf(AgentAlert.Finished(agent("a", AgentStatus.Done))), t.update(listOf(agent("a", AgentStatus.Done))))
    }

    @Test
    fun reconnectSetsTheStartAgain() {
        val t = HerdrTracker()
        t.update(listOf(agent("a", AgentStatus.Working), agent("b", AgentStatus.Blocked)))
        t.restart()
        val alerts = t.update(listOf(agent("a", AgentStatus.Done)))
        assertEquals("a change while offline posts nothing, and a gone pane clears", listOf(AgentAlert.Clear("b")), alerts)
        assertEquals(listOf(AgentAlert.NeedsInput(agent("a", AgentStatus.Blocked))), t.update(listOf(agent("a", AgentStatus.Blocked))))
    }
}
