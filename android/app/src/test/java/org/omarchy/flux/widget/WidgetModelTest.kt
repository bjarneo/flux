package org.omarchy.flux.widget

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test
import org.omarchy.flux.core.AgentStatus
import org.omarchy.flux.core.ApproveRequest
import org.omarchy.flux.core.DeviceUi
import org.omarchy.flux.core.HerdrAgent
import org.omarchy.flux.core.HerdrState
import org.omarchy.flux.core.PairState
import org.omarchy.flux.core.SeenClock
import org.omarchy.flux.core.ThemeMode
import org.omarchy.flux.theme.NON_TEXT_CONTRAST
import org.omarchy.flux.theme.OmarchyTheme
import org.omarchy.flux.theme.SampleThemes
import org.omarchy.flux.theme.TEXT_CONTRAST
import org.omarchy.flux.theme.TokyoNight
import org.omarchy.flux.theme.TokyoNightDay
import org.omarchy.flux.theme.contrast
import org.omarchy.flux.theme.paletteOf
import org.omarchy.flux.theme.resolvePalette

class WidgetModelTest {
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
        agentSince = since, lastSeen = lastSeen,
    )

    private val migrate = HerdrAgent("w2:p1", "codex", AgentStatus.Blocked, "Run the database migration", "billing")
    private val refactor = HerdrAgent("w1:p1", "claude", AgentStatus.Working, "Refactor the sync loop", "flux")
    private val flaky = HerdrAgent("w3:p1", "claude", AgentStatus.Done, "Fix the flaky login test", "web")
    private val idle = HerdrAgent("w3:p2", "pi", AgentStatus.Idle, "", "", "web")

    private fun approval(computer: String, time: Long = 1) = ApproveRequest(
        computerId = computer, computerName = "omarchy-xps", id = "r1", kind = ApproveRequest.Kind.Approve,
        host = "omarchy-xps", user = "dev", service = "sudo", tty = "pts/3", rhost = "", time = time, nonce = "", timeoutSeconds = 30,
    )

    private fun model(devices: List<DeviceUi>, approval: ApproveRequest? = null, enabled: Boolean = true, connecting: Boolean = false) =
        widgetModel(devices, approval, enabled, connecting, SeenClock(), now = 9_000)

    @Test
    fun whatNeedsTheUserComesFirstThenTheAgentsThatWorkAndFinish() {
        val pc = device(
            "pc", "omarchy-xps",
            agents = listOf(refactor, flaky, idle, migrate),
            since = mapOf("w2:p1" to 5_000L, "w1:p1" to 100L, "w3:p1" to 200L, "w3:p2" to 300L),
        )
        val m = model(listOf(pc), approval("pc"))
        assertEquals(listOf("agent|pc|w2:p1", "approve|pc|r1", "agent|pc|w1:p1", "agent|pc|w3:p1", "agent|pc|w3:p2"), m.rows.map { it.key })
        assertEquals(2, m.needs)
        assertNull(m.quiet)

        val (blocked, sudo, working, done, rest) = m.rows
        assertEquals("Run the database migration", blocked.title)
        assertEquals("Needs input", blocked.status)
        assertEquals(WidgetTone.Needs, blocked.tone)
        assertEquals("codex · billing", blocked.source)
        assertEquals("omarchy-xps", blocked.computer)
        assertTrue(blocked.needs)
        assertFalse("an agent has the thin border", blocked.strong)
        assertEquals("a tap opens the chat of the agent", WidgetTarget.Agent("pc", "w2:p1"), blocked.target)

        assertEquals("Approve sudo on omarchy-xps?", sudo.title)
        assertEquals("Needs approval", sudo.status)
        assertEquals("user dev · pts/3", sudo.source)
        assertTrue("an approval has the strong border", sudo.strong)
        assertEquals(WidgetTarget.Approval("pc"), sudo.target)

        assertEquals(WidgetTone.Works, working.tone)
        assertFalse(working.needs)
        assertEquals(WidgetTone.Done, done.tone)
        assertEquals("Done", done.status)
        assertEquals("an agent with no task shows its pane", "w3:p2", rest.title)
        assertEquals("an agent with no project shows its workspace", "pi · web", rest.source)
        assertEquals(WidgetTone.Quiet, rest.tone)
    }

    @Test
    fun aPairRequestNeedsTheUserAndOpensChats() {
        val pc = device("pc", "omarchy-xps")
        val fw = device("fw", "framework-13", paired = false, pairState = PairState.Incoming)
        val m = model(listOf(pc, fw))
        val row = m.rows.single()
        assertEquals("framework-13 asks to pair", row.title)
        assertEquals("Pair request", row.status)
        assertTrue(row.needs && row.strong)
        assertEquals(WidgetTarget.Chats, row.target)
        assertEquals(1, m.needs)
    }

    @Test
    fun theAgentsOfEachComputerShowWithTheirComputer() {
        val pc = device("pc", "omarchy-xps", agents = listOf(refactor))
        val desk = device("desk", "omarchy-desk", agents = listOf(flaky.copy(pane = "w9:p1")))
        val m = model(listOf(pc, desk))
        assertEquals(setOf("omarchy-xps", "omarchy-desk"), m.rows.map { it.computer }.toSet())
        assertEquals("2 of 2 online", m.contextText(wide = true).substringAfter(" · "))
    }

    @Test
    fun eachQuietStateHasNoRows() {
        assertEquals(WidgetQuiet.Off, model(listOf(device("pc", "omarchy-xps", agents = listOf(migrate))), enabled = false).quiet)
        assertEquals(WidgetQuiet.Unpaired, model(emptyList()).quiet)
        assertEquals(WidgetQuiet.NoAgents, model(listOf(device("pc", "omarchy-xps"))).quiet)
        assertEquals(WidgetQuiet.Connecting, model(listOf(device("pc", "omarchy-xps", online = false)), connecting = true).quiet)

        // A computer that is not reachable adds no agents, so its old agents do not show.
        val away = model(listOf(device("pc", "omarchy-xps", online = false, agents = listOf(migrate), lastSeen = 500)))
        assertEquals(WidgetQuiet.Offline, away.quiet)
        assertTrue(away.rows.isEmpty())
        assertEquals(0, away.needs)
        assertEquals("omarchy-xps", away.name)
        assertEquals(500L, away.lastSeen)
    }

    @Test
    fun theQuietTextIsPlain() {
        val time = { _: Long -> "at 09:12" }
        val away = model(listOf(device("pc", "omarchy-xps", online = false, lastSeen = 500), device("desk", "omarchy-desk", online = false)))
        assertEquals("No computer is connected" to "omarchy-xps was last seen at 09:12.", away.quietText(time))
        val never = model(listOf(device("pc", "omarchy-xps", online = false)))
        assertEquals("omarchy-xps is not reachable.", never.quietText(time).second)
        assertEquals("Nothing needs you" to "No agents run on omarchy-xps.", model(listOf(device("pc", "omarchy-xps"))).quietText(time))
        assertEquals("Connecting to omarchy-xps", model(listOf(device("pc", "omarchy-xps", online = false)), connecting = true).quietText(time).first)
        assertEquals("Flux is off", model(emptyList(), enabled = false).quietText(time).first)
        assertEquals("No computer is paired", model(emptyList()).quietText(time).first)
    }

    @Test
    fun theHeaderCountsWhatNeedsTheUser() {
        val one = model(listOf(device("pc", "omarchy-xps", agents = listOf(migrate))))
        assertEquals("1 needs you", one.needsText())
        assertEquals(" · 1 of 1 online", one.contextText(wide = true))
        assertEquals("a narrow widget shows only the count", "", one.contextText(wide = false))
        val two = model(listOf(device("pc", "omarchy-xps", agents = listOf(migrate))), approval("pc"))
        assertEquals("2 need you", two.needsText())
        val calm = model(listOf(device("pc", "omarchy-xps", agents = listOf(refactor)), device("desk", "omarchy-desk", online = false)))
        assertEquals("", calm.needsText())
        assertEquals("nothing needs you · 1 of 2 online", calm.contextText(wide = true))
        assertEquals("nothing needs you", calm.contextText(wide = false))
        assertEquals("offline", model(listOf(device("pc", "omarchy-xps", online = false))).contextText(wide = false))
        assertEquals("the quiet title tells the state", "0 of 1 online", model(listOf(device("pc", "omarchy-xps", online = false))).contextText(wide = true))
        assertEquals("off", model(listOf(device("pc", "omarchy-xps")), enabled = false).contextText(wide = true))
        assertEquals("a pair request with no paired computer has no online count", "", model(listOf(device("fw", "framework-13", paired = false, pairState = PairState.Incoming))).contextText(wide = true))
    }

    @Test
    fun aSmallWidgetShowsTheHeaderAndTheFirstRow() {
        // 2 by 1 cells in portrait on Android 12 and later.
        val small = widgetFit(130f, 102f, 1f, total = 4)
        assertEquals(1, small.rows)
        assertFalse("1 row has no room for the line of the rest", small.more)
        assertFalse(small.wide)
        assertTrue("2 cells have no room for the source", small.compact)
        assertFalse(widgetFit(203f, 102f, 1f, total = 4).compact)
        assertEquals("with no room for a row, only the header shows", 0, widgetFit(130f, 80f, 1f, total = 4).rows)
    }

    @Test
    fun aLargerWidgetShowsMoreRowsAndTellsAboutTheRest() {
        // 4 by 2 cells in portrait.
        val all = widgetFit(276f, 220f, 1f, total = 3)
        assertEquals(WidgetFit(wide = true, rows = 3, more = false), all)
        // A third row fits, but not with the line under it, so the header tells about the rest.
        val cut = widgetFit(276f, 220f, 1f, total = 6)
        assertEquals(WidgetFit(wide = true, rows = 3, more = false), cut)
        val pc = device("pc", "omarchy-xps", agents = listOf(migrate, refactor, flaky, idle))
        assertEquals(" · 1 more", model(listOf(pc)).contextText(wide = true, hidden = 1))
        assertEquals("nothing needs you · 2 more", model(listOf(device("pc", "omarchy-xps", agents = listOf(refactor)))).contextText(wide = false, hidden = 2))
        // With room for the line, the line tells about the rest.
        val line = widgetFit(276f, 250f, 1f, total = 6)
        assertEquals(WidgetFit(wide = true, rows = 3, more = true), line)
        assertEquals("3 more in Chats", moreText(6 - line.rows))
        assertEquals("a tall widget stops at the most rows", WIDGET_MAX_ROWS, widgetFit(276f, 2_000f, 1f, total = 40).rows)
    }

    @Test
    fun aLargeFontGivesFewerRows() {
        val normal = widgetFit(276f, 337f, 1f, total = 9).rows
        val large = widgetFit(276f, 337f, 2f, total = 9).rows
        assertTrue("$large rows at 200% against $normal at 100%", large in 1 until normal)
        // Large text needs more width, so a widget of 4 cells takes the narrow form.
        assertTrue(widgetFit(276f, 337f, 1f, total = 9).wide)
        assertFalse(widgetFit(276f, 337f, 1.4f, total = 9).wide)
        assertFalse(widgetFit(276f, 337f, 1.4f, total = 9).compact)
    }

    private fun palettes() = listOf(TokyoNight, TokyoNightDay) + SampleThemes.all.map(::paletteOf) +
        paletteOf(OmarchyTheme("bright", false, mapOf("background" to 0xFFFFFF, "foreground" to 0xAAAAAA, "accent" to 0xFF0000, "red" to 0xFF5555)))

    @Test
    fun eachColorOfTheWidgetHoldsWcagAaInEachTheme() {
        for (p in palettes()) {
            val c = WidgetColors.of(p)
            for (g in c.grounds) {
                for (ink in c.inks) {
                    val r = contrast(ink, g)
                    assertTrue("${p.name}: text %06X on %06X is %.2f:1".format(ink, g, r), r >= TEXT_CONTRAST)
                }
                for (mark in c.marks) {
                    val r = contrast(mark, g)
                    assertTrue("${p.name}: mark %06X on %06X is %.2f:1".format(mark, g, r), r >= NON_TEXT_CONTRAST)
                }
            }
            for (t in WidgetTone.entries) {
                assertTrue(c.ink(t) in c.inks)
                assertTrue(c.dot(t) in c.marks)
            }
        }
    }

    @Test
    fun aComputerThemeHasTheSameColorsInTheLightAndTheDarkMode() {
        val latte = paletteOf(SampleThemes.byName("catppuccin-latte")!!)
        assertEquals(resolvePalette(ThemeMode.Computer, latte, false), resolvePalette(ThemeMode.Computer, latte, true))
        // Without a computer theme, the widget follows the mode of the phone, as the app does.
        assertEquals(TokyoNightDay, resolvePalette(ThemeMode.Computer, null, false))
        assertEquals(TokyoNight, resolvePalette(ThemeMode.Computer, null, true))
    }
}
