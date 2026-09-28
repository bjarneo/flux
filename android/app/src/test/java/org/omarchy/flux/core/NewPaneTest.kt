package org.omarchy.flux.core

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class NewPaneTest {
    private val state = HerdrState(
        enabled = true,
        running = true,
        control = true,
        agents = listOf(
            HerdrAgent("w2:p1", "claude", AgentStatus.Idle, workspace = "flux"),
            HerdrAgent("w2:p2", "codex", AgentStatus.Working, workspace = "flux"),
            HerdrAgent("w3:p1", "claude", AgentStatus.Done, workspace = "web"),
        ),
        workspaces = listOf(
            HerdrWorkspace("w1", "notes", "~"),
            HerdrWorkspace("w2", "flux", "~/Code/flux/"),
            HerdrWorkspace("w3", "web", "~/Code/web"),
            HerdrWorkspace("w4", "flux 2", "~/Code/flux"),
            HerdrWorkspace("w5", "empty", ""),
            HerdrWorkspace("w6", "srv", "/srv/app"),
        ),
    )

    @Test
    fun foldersComeOnceAfterHome() {
        val folders = folderChoices(state)
        assertEquals(listOf("~", "~/Code/flux", "~/Code/web", "/srv/app"), folders.map { it.path })
        assertEquals(listOf("home", "flux", "web", "app"), folders.map { it.name })
        assertEquals("the first workspace of a folder wins", "w2", folders[1].workspace?.id)
        assertEquals(listOf(0, 2, 1, 0), folders.map { it.agents })
        assertEquals("w1", folders[0].workspace?.id)
    }

    @Test
    fun homeWithoutWorkspace() {
        val folders = folderChoices(state.copy(workspaces = listOf(HerdrWorkspace("w3", "web", "~/Code/web"))))
        assertEquals(listOf("~", "~/Code/web"), folders.map { it.path })
        assertNull(folders[0].workspace)
    }

    @Test
    fun filtersByNameOrPath() {
        val folders = folderChoices(state)
        assertEquals(listOf("~/Code/flux"), filterFolders(folders, "FLU").map { it.path })
        assertEquals(listOf("~/Code/flux", "~/Code/web"), filterFolders(folders, "code").map { it.path })
        assertEquals(folders, filterFolders(folders, "  "))
    }

    @Test
    fun matchesTheWorkspaceOfAFolder() {
        assertEquals("w2", workspaceFor(state, "~/Code/flux")?.id)
        assertEquals("a slash at the end does not matter", "w2", workspaceFor(state, "~/Code/flux/")?.id)
        assertEquals("w1", workspaceFor(state, "~")?.id)
        assertNull(workspaceFor(state, "~/Code/other"))
        assertNull("a workspace without a folder matches nothing", workspaceFor(state, ""))
    }

    @Test
    fun folderNamesAndPaths() {
        assertEquals("home", folderName("~"))
        assertEquals("home", folderName("~/"))
        assertEquals("flux", folderName("~/Code/flux/"))
        assertEquals("/", folderName("/"))
        assertEquals("/", normalFolder("/"))
        assertEquals("~/a", normalFolder(" ~/a// "))
        assertTrue(looksLikePath("~/Code"))
        assertTrue(looksLikePath(" /srv"))
        assertFalse(looksLikePath("flux"))
    }

    @Test
    fun picksTheRun() {
        val kinds = listOf("codex", "claude", "opencode")
        assertEquals("the last choice stays", "opencode", pickRun("opencode", kinds, shell = false))
        assertEquals("a missing agent gives claude", "claude", pickRun("gemini", kinds, shell = true))
        assertEquals("codex", pickRun(null, listOf("codex", "opencode"), shell = true))
        assertEquals(SHELL_CHOICE, pickRun(SHELL_CHOICE, kinds, shell = true))
        assertEquals("a terminal needs terminals", "claude", pickRun(SHELL_CHOICE, kinds, shell = false))
        assertEquals(SHELL_CHOICE, pickRun(null, emptyList(), shell = true))
        assertNull(pickRun("claude", emptyList(), shell = false))
    }

    @Test
    fun productNames() {
        assertEquals("Claude Code", agentProduct("claude"))
        assertNull(agentProduct("somethingnew"))
    }
}
