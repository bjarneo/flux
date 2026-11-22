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
    fun choicesWaitForTheNextOutputAfterAnAnswer() {
        val question = HerdrOutput("w1:p1", loading = false)
        assertTrue("no answer yet", choicesOpen(question, answered = null, sending = false))
        assertFalse("a reply sends", choicesOpen(question, answered = null, sending = true))
        assertFalse("the answered output", choicesOpen(question, answered = question, sending = false))
        // The read after the answer keeps the old lines on screen while it loads.
        val reading = question.copy(loading = true)
        assertFalse("the next output loads", choicesOpen(reading, answered = question, sending = false))
        val next = reading.copy(loading = false)
        assertTrue("the next output", choicesOpen(next, answered = question, sending = false))
        assertFalse("the next output while a reply sends", choicesOpen(next, answered = question, sending = true))
        assertFalse("no output after an answer", choicesOpen(null, answered = question, sending = false))
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
    fun anOutputKeepsTheTimeOfItsParse() {
        val o = parseHerdrOutput(body("""{"kind":"output","pane":"w5:p1","text":"a"}"""), now = 42_000L)!!
        assertEquals(42_000L, o.at)
        assertEquals("a read that waits has no time", 0L, HerdrOutput("w5:p1").at)
        val e = parseHerdrOutput(body("""{"kind":"output","pane":"w5:p1","error":"gone"}"""), now = 7L)!!
        assertEquals(7L, e.at)
    }

    @Test
    fun tidiesRules() {
        val rule = "─".repeat(120)
        val lines = termLines("$rule\n❯ 1. Yes  \n  \n")
        assertEquals("$rule\n❯ 1. Yes", lines.joinToString("\n") { it.text })
        assertEquals("the screen fits the rule to its width", "─".repeat(40) + "\n❯ 1. Yes", fitLines(lines, 40).joinToString("\n") { it.text })
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
    fun clockKnowsOnlyTheChangesThatItSaw() {
        val c = AgentClock()
        // The first state after a connection: the start of each status is not known.
        assertTrue(c.update(listOf(agent("a", AgentStatus.Blocked), agent("b", AgentStatus.Working)), 1_000).isEmpty())
        val next = c.update(listOf(agent("a", AgentStatus.Working), agent("b", AgentStatus.Working), agent("c", AgentStatus.Blocked)), 5_000)
        assertEquals(mapOf("a" to 5_000L, "c" to 5_000L), next)
        // The same status keeps its time, and an unknown status keeps the last status and its time.
        assertEquals(mapOf("a" to 5_000L, "c" to 5_000L), c.update(listOf(agent("a", AgentStatus.Unknown), agent("c", AgentStatus.Blocked)), 9_000))
        // A connection again keeps the times that the phone saw, and an agent that is gone leaves.
        c.restart()
        assertEquals(mapOf("a" to 5_000L), c.update(listOf(agent("a", AgentStatus.Working), agent("d", AgentStatus.Done)), 12_000))
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

    private val sessionsState = """{"kind":"state","enabled":true,"running":true,"control":true,"terminals":true,
        "agents":[{"pane":"w1:p1","agent":"claude","status":"idle"}],
        "panes":[{"pane":"w1:p2"}],
        "workspaces":[{"id":"w1","label":"flux","cwd":"~/Code/flux"}],
        "kinds":["claude"],
        "sessions":[
          {"name":"default","default":true,"running":true,
           "agents":[{"pane":"w1:p1","agent":"claude","status":"idle"}],
           "panes":[{"pane":"w1:p2"}],
           "workspaces":[{"id":"w1","label":"flux","cwd":"~/Code/flux"}]},
          {"name":"omarchy","default":false,"running":true,
           "agents":[{"pane":"omarchy/w1:p1","agent":"codex","status":"blocked"},{"pane":"omarchy/w2:p1","agent":"claude","status":"working"}],
           "panes":[{"pane":"omarchy/w3:p2"}],
           "workspaces":[{"id":"omarchy/w1","label":"omarchy","cwd":"~/Code/omarchy"}]}
        ]}"""

    @Test
    fun parsesSessions() {
        val s = parseHerdrState(body(sessionsState))!!
        assertEquals(
            listOf(HerdrSessionInfo("default", default = true, running = true), HerdrSessionInfo("omarchy", default = false, running = true)),
            s.sessions,
        )
        assertTrue(s.manySessions)
        assertEquals("the lists hold all sessions", listOf("w1:p1", "omarchy/w1:p1", "omarchy/w2:p1"), s.agents.map { it.pane })
        assertEquals(listOf("default", "omarchy", "omarchy"), s.agents.map { it.session })
        assertEquals(listOf("w1:p2", "omarchy/w3:p2"), s.panes.map { it.pane })
        assertEquals(HerdrWorkspace("omarchy/w1", "omarchy", "~/Code/omarchy", "omarchy"), s.workspaces[1])
        assertEquals("a lookup finds an agent of any session", "codex", s.agent("omarchy/w1:p1")?.agent)
        assertEquals("omarchy", s.terminal("omarchy/w3:p2")?.session)
        assertEquals(1, s.blocked)
        assertEquals(0, s.blockedIn("default"))
        assertEquals(1, s.blockedIn("omarchy"))
        assertEquals("Default", s.sessionList[0].label)
        assertEquals("omarchy", s.sessionList[1].label)
    }

    @Test
    fun sessionsKeepThePermissions() {
        val s = parseHerdrState(body(sessionsState.replace("\"control\":true", "\"control\":false")))!!
        assertTrue("terminals need control", s.panes.isEmpty())
        assertTrue("workspaces need control", s.workspaces.isEmpty())
        assertEquals(3, s.agents.size)
        val off = parseHerdrState(body(sessionsState.replace("\"enabled\":true", "\"enabled\":false")))!!
        assertFalse(off.anyRunning)
        assertTrue(off.sessions.none { it.running })
    }

    @Test
    fun parsesStateWithoutSessions() {
        val s = parseHerdrState(
            body(
                """{"kind":"state","enabled":true,"running":true,"control":true,"terminals":true,
                "agents":[{"pane":"w1:p1","agent":"claude","status":"blocked"}],"panes":[{"pane":"w1:p2"}],
                "workspaces":[{"id":"w1","label":"flux"}]}""",
            ),
        )!!
        assertTrue(s.sessions.isEmpty())
        assertEquals(listOf(HerdrSessionInfo("default", default = true, running = true)), s.sessionList)
        assertFalse("no picker with only the default session", s.manySessions)
        assertEquals(HerdrAgent("w1:p1", "claude", AgentStatus.Blocked), s.agents.single())
        assertEquals(HERDR_DEFAULT_SESSION, s.panes.single().session)
        assertEquals(HERDR_DEFAULT_SESSION, s.workspaces.single().session)
        assertTrue("one session scopes to itself", s.scoped("omarchy") === s)
        assertEquals(1, s.blockedIn("default"))

        val empty = parseHerdrState(body("""{"kind":"state","enabled":true,"running":false,"agents":[{"pane":"w1:p1"}],"sessions":[]}"""))!!
        assertEquals("an empty list is like no list", listOf("w1:p1"), empty.agents.map { it.pane })
        assertFalse(empty.anyRunning)
        assertFalse(empty.sessionList.single().running)
    }

    @Test
    fun scopesToASession() {
        val s = parseHerdrState(body(sessionsState))!!
        val omarchy = s.scoped("omarchy")
        assertEquals(listOf("omarchy/w1:p1", "omarchy/w2:p1"), omarchy.agents.map { it.pane })
        assertEquals(listOf("omarchy/w3:p2"), omarchy.panes.map { it.pane })
        assertEquals(listOf("omarchy/w1"), omarchy.workspaces.map { it.id })
        assertEquals(1, omarchy.blocked)
        assertEquals("the kinds apply to each session", listOf("claude"), omarchy.kinds)
        assertTrue(omarchy.control)

        val default = s.scoped("default")
        assertEquals(listOf("w1:p1"), default.agents.map { it.pane })
        assertEquals(listOf("w1"), default.workspaces.map { it.id })
        assertEquals("a session that is gone shows the default session", default, s.scoped("gone"))
        assertEquals("no pick shows the default session", default, s.scoped(null))
        assertEquals("default", s.sessionOrDefault("gone").name)
        assertEquals("omarchy", s.sessionOrDefault("omarchy").name)
    }

    @Test
    fun scopedSessionTakesItsRunningState() {
        val s = parseHerdrState(body(sessionsState.replace("\"running\":true", "\"running\":false")))!!
        assertFalse(s.running)
        assertFalse(s.anyRunning)
        val named = HerdrState(
            enabled = true, running = false, agents = emptyList(),
            sessions = listOf(HerdrSessionInfo("default", true, false), HerdrSessionInfo("omarchy", false, true)),
        )
        assertTrue("a named session runs without the default one", named.anyRunning)
        assertTrue(named.scoped("omarchy").running)
        assertFalse(named.scoped("default").running)
    }

    @Test
    fun createNamesTheSessionOfANewWorkspace() {
        val plain = herdrCreateBody("agent", "claude", " ~/Code/flux ", "", null, 4)
        assertEquals("create", plain.str("kind"))
        assertEquals("~/Code/flux", plain.str("cwd"))
        assertEquals("", plain.str("workspace"))
        assertEquals(4L, plain["request"]?.let { (it as JsonPrimitive).content.toLong() })
        assertNull(plain["herdr_session"])
        assertNull("the default session is not named", herdrCreateBody("agent", "claude", "~", "", HERDR_DEFAULT_SESSION, 1)["herdr_session"])

        val named = herdrCreateBody("terminal", "", "~/Code/omarchy", "", "omarchy", 5)
        assertEquals("omarchy", named.str("herdr_session"))
        assertNull("it is not the stream session", named["session"])
        assertNull(
            "a new tab takes the session of its workspace",
            herdrCreateBody("agent", "claude", "~", "omarchy/w1", "omarchy", 6)["herdr_session"],
        )
        assertEquals(
            "without a session, the body is as before",
            setOf("kind", "what", "agent", "cwd", "workspace", "request"),
            plain.keys,
        )
    }
}
