package org.omarchy.flux.core

/**
 * The choices of the screen that starts a herdr agent or opens a
 * terminal. The functions have no Android imports, so the JVM tests can
 * load them.
 */

/** The run choice for a plain terminal. Agent kinds are never empty. */
const val SHELL_CHOICE = ""

/**
 * A folder where a new pane can open. [path] is the folder as the computer
 * sends it, often with `~/`. [workspace] is the first workspace in that
 * folder, or null. [agents] counts the agents in that workspace.
 */
data class FolderChoice(val path: String, val name: String, val workspace: HerdrWorkspace?, val agents: Int)

/** Returns the folder without a slash at its end. `/` and `~` stay. */
fun normalFolder(path: String): String {
    val p = path.trim()
    return if (p.length > 1) p.trimEnd('/').ifEmpty { "/" } else p
}

/** The last part of a folder, or "home" for the home folder. */
fun folderName(path: String): String {
    val p = normalFolder(path)
    return when (p) {
        "", "~" -> "home"
        "/" -> "/"
        else -> p.substringAfterLast('/')
    }
}

/** True when [text] is a folder path and not a search: it starts with `/` or `~`. */
fun looksLikePath(text: String): Boolean = text.trim().let { it.startsWith("/") || it.startsWith("~") }

/**
 * The folders of the workspaces in sidebar order, each once, after the
 * home folder. A workspace without a folder is left out.
 */
fun folderChoices(state: HerdrState): List<FolderChoice> {
    val out = LinkedHashMap<String, FolderChoice>()
    out["~"] = FolderChoice("~", "home", workspaceFor(state, "~"), 0)
    for (w in state.workspaces) {
        val path = normalFolder(w.cwd)
        if (path.isEmpty() || path in out) continue
        out[path] = FolderChoice(path, folderName(path), w, state.agents.count { it.workspace == w.label })
    }
    val home = out.getValue("~")
    if (home.workspace != null) out["~"] = home.copy(agents = state.agents.count { it.workspace == home.workspace.label })
    return out.values.toList()
}

/** The folders whose name or path has [query], without regard to case. An empty query keeps all. */
fun filterFolders(folders: List<FolderChoice>, query: String): List<FolderChoice> {
    val q = query.trim()
    if (q.isEmpty()) return folders
    return folders.filter { it.name.contains(q, ignoreCase = true) || it.path.contains(q, ignoreCase = true) }
}

/** The first workspace in sidebar order whose folder is [folder], or null. */
fun workspaceFor(state: HerdrState, folder: String): HerdrWorkspace? {
    val f = normalFolder(folder)
    return state.workspaces.firstOrNull { it.cwd.isNotEmpty() && normalFolder(it.cwd) == f }
}

/** The product name of an agent kind, or null when Flux does not know it. */
fun agentProduct(kind: String): String? = when (kind) {
    "claude" -> "Claude Code"
    "codex" -> "Codex CLI"
    "opencode" -> "OpenCode"
    "gemini" -> "Gemini CLI"
    "copilot" -> "GitHub Copilot"
    "cursor" -> "Cursor Agent"
    "amp" -> "Amp"
    "qwen" -> "Qwen Code"
    "kimi" -> "Kimi CLI"
    "muse" -> "Muse Code"
    "grok" -> "Grok CLI"
    "agy" -> "Antigravity"
    "cline" -> "Cline"
    else -> null
}

/**
 * The run choice to select: [last] when the computer still offers it,
 * then claude, then the first agent, then a terminal. Empty when the
 * computer offers nothing.
 */
fun pickRun(last: String?, kinds: List<String>, shell: Boolean): String? = when {
    last != null && last != SHELL_CHOICE && last in kinds -> last
    last == SHELL_CHOICE && shell -> SHELL_CHOICE
    "claude" in kinds -> "claude"
    kinds.isNotEmpty() -> kinds.first()
    shell -> SHELL_CHOICE
    else -> null
}
