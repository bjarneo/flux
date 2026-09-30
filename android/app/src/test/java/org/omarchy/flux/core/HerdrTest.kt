package org.omarchy.flux.core

import kotlinx.serialization.json.JsonObject
import kotlinx.serialization.json.JsonPrimitive
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.protocol.INCOMING
import org.omarchy.flux.protocol.OUTGOING
import org.omarchy.flux.protocol.Packet
import org.omarchy.flux.protocol.Types
import org.omarchy.flux.protocol.bool
import org.omarchy.flux.protocol.str

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
    fun parsesTerminalsWorkspacesAndKinds() {
        val s = parseHerdrState(
            body(
                """{"kind":"state","enabled":true,"running":true,"control":true,"terminals":true,"agents":[],
                "panes":[{"pane":"w1:p2","title":"npm run dev","project":"web","workspace":"web"},{"title":"no pane"}],
                "workspaces":[{"id":"w1","label":"web","cwd":"/src/web"},{"id":"w2"},{"label":"no id"}],
                "kinds":["claude","","codex"]}""",
            ),
        )!!
        assertTrue(s.control)
        assertTrue(s.terminals)
        assertEquals(listOf(HerdrTerminal("w1:p2", "npm run dev", "web", "web")), s.panes)
        assertEquals(HerdrTerminal("w1:p2", "npm run dev", "web", "web"), s.terminal("w1:p2"))
        assertEquals(listOf(HerdrWorkspace("w1", "web", "/src/web"), HerdrWorkspace("w2", "w2")), s.workspaces)
        assertEquals("an empty kind is dropped", listOf("claude", "codex"), s.kinds)

        val noControl = parseHerdrState(
            body("""{"kind":"state","enabled":true,"running":true,"control":false,"terminals":true,"panes":[{"pane":"w1:p2"}],"kinds":["claude"]}"""),
        )!!
        assertFalse("terminals need control", noControl.terminals)
        assertTrue(noControl.panes.isEmpty())
        assertTrue(noControl.kinds.isEmpty())
    }

    @Test
    fun parsesCreatedAndClosed() {
        assertEquals(HerdrDone("create", "w4:p1", null, "agent"), parseHerdrDone(body("""{"kind":"created","what":"agent","pane":"w4:p1"}""")))
        assertEquals(HerdrDone("create", null, "The folder /x does not exist"), parseHerdrDone(body("""{"kind":"created","error":"The folder /x does not exist"}""")))
        assertEquals(HerdrDone("close", "w4:p1", null), parseHerdrDone(body("""{"kind":"closed","pane":"w4:p1"}""")))
        assertNull(parseHerdrDone(body("""{"kind":"sent","pane":"w4:p1"}""")))
    }

    @Test
    fun parsesRequestNumbers() {
        // A newer fluxd sends the number of the request back, so a late answer does not end a newer request.
        assertEquals(HerdrDone("create", "w4:p1", null, "agent", 3), parseHerdrDone(body("""{"kind":"created","what":"agent","pane":"w4:p1","request":3}""")))
        assertEquals(HerdrSent("w1:p1", "prompt", null, 7), parseHerdrSent(body("""{"kind":"sent","pane":"w1:p1","action":"prompt","request":7}""")))
        assertNull(parseHerdrSent(body("""{"kind":"sent","pane":"w1:p1","action":"keys"}"""))!!.request)
    }

    @Test
    fun keepsBlockedMessage() {
        val sent = parseHerdrSent(
            body("""{"kind":"sent","pane":"w1:p1","action":"prompt","code":"blocked","error":"The agent waits for a choice. Pick a choice first."}"""),
        )
        assertEquals("The agent waits for a choice. Pick a choice first.", sent!!.error)
        assertEquals(HERDR_BLOCKED, sent.code)
        assertNull("an answer without a code has none", parseHerdrSent(body("""{"kind":"sent","pane":"w1:p1","action":"prompt","error":"x"}"""))!!.code)
    }

    @Test
    fun onlySendAsAnswerSetsTheAnswerFlag() {
        val prompt = herdrPromptBody("w1:p1", "Use Postgres", answer = false)
        assertEquals("prompt", prompt.str("kind"))
        assertEquals("Use Postgres", prompt.str("text"))
        assertNull("a normal Send has no answer field", prompt["answer"])
        val answer = herdrPromptBody("w1:p1", "Use Postgres", answer = true)
        assertEquals(true, answer.bool("answer"))
        assertEquals("the same text goes again", "Use Postgres", answer.str("text"))
    }

    @Test
    fun anAnswerWithARequestNumberMatchesOnlyThatReply() {
        val reply = HerdrReply("w1:p1", "prompt", seq = 5)
        assertTrue(HerdrSent("w1:p1", "prompt", null, request = 5).answers(reply))
        assertFalse("a late answer to an earlier reply", HerdrSent("w1:p1", "prompt", null, request = 4).answers(reply))
        assertFalse("a reply that got its answer", HerdrSent("w1:p1", "prompt", null, request = 5).answers(reply.copy(sending = false)))
        assertFalse("another pane", HerdrSent("w2:p1", "prompt", null, request = 5).answers(reply))

        val create = HerdrAction("create", seq = 3, what = "agent")
        assertTrue(HerdrDone("create", "w4:p1", null, "agent", request = 3).answers(create))
        assertFalse("a late answer to an earlier create", HerdrDone("create", "w4:p1", null, "agent", request = 2).answers(create))
    }

    @Test
    fun anAnswerWithoutARequestNumberMatchesThePaneAndTheAction() {
        // An older fluxd sends no number back.
        val reply = HerdrReply("w1:p1", "prompt", seq = 5)
        assertTrue(HerdrSent("w1:p1", "prompt", null).answers(reply))
        assertTrue("an answer without an action", HerdrSent("w1:p1", "", null).answers(reply))
        assertFalse("an answer to keys", HerdrSent("w1:p1", "keys", null).answers(reply))
        assertFalse("another pane", HerdrSent("w2:p1", "prompt", null).answers(reply))

        val close = HerdrAction("close", seq = 3, pane = "w4:p1")
        assertTrue(HerdrDone("close", "w4:p1", null).answers(close))
        assertFalse("another pane", HerdrDone("close", "w5:p1", null).answers(close))
        val create = HerdrAction("create", seq = 4, what = "terminal")
        assertTrue(HerdrDone("create", "w4:p2", null, "terminal").answers(create))
        assertFalse("a late answer to a new agent", HerdrDone("create", "w4:p2", null, "agent").answers(create))
        assertFalse("a close is not a create", HerdrDone("close", "w4:p2", null).answers(create))
    }

    @Test
    fun terminalKeys() {
        assertTrue("ctrl+c" in HERDR_TERMINAL_KEYS)
        assertTrue("ctrl+z" in HERDR_TERMINAL_KEYS)
        assertFalse("f1" in HERDR_TERMINAL_KEYS)
        assertFalse("ctrl+c" in HERDR_KEYS)
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

    private fun output(text: String) = JsonObject(
        mapOf("kind" to JsonPrimitive("output"), "pane" to JsonPrimitive("w1:p1"), "text" to JsonPrimitive(text)),
    )

    @Test
    fun herdrOutputIsCapped() {
        val many = (1..HERDR_MAX_LINES + 500).joinToString("\n") { "row $it" }
        val out = parseHerdrOutput(output(many))
        assertNotNull(out)
        assertTrue(out!!.truncated)
        assertTrue(out.lines.size <= HERDR_MAX_LINES)
        assertEquals("row ${HERDR_MAX_LINES + 500}", out.lines.last().text)

        val big = parseHerdrOutput(output("z".repeat(100) + "\n" + "y".repeat(HERDR_MAX_TEXT)))!!
        assertTrue(big.truncated)
        assertTrue(big.lines.all { it.text.length <= TERM_MAX_COLUMNS })
    }
}
