package org.omarchy.flux.core

import android.content.Context
import android.os.Build

/**
 * Debug builds only: posts a sample agent notification for a screenshot.
 * `notify:agent` has 3 choices, `notify:agent-reply` has a question with
 * free text, `notify:agent-four` has 4 choices, and
 * `notify:agent-readonly` has 3 choices with Agent control off. The
 * actions of a sample notification find no computer to answer, so they open
 * the thread.
 */
object DebugAgentNotice {
    private val agent = HerdrAgent("w2:p1", "codex", AgentStatus.Blocked, "Run the database migration", "billing", "billing")

    private val three = "● Bash command\n\n   bin/migrate --apply\n   Apply the pending migration\n\n Do you want to proceed?\n" +
        " ❯ 1. Yes\n   2. Yes, and do not ask again for bin/migrate commands\n   3. No\n"

    private val four = three + "   4. No, and tell Codex what to do differently\n"

    private val free = "● I can migrate one database.\n\n Which database should I migrate: staging or production?\n"

    /** The sample dialog for [kind], or null for an unknown kind. */
    private fun dialog(kind: String): AgentDialog? {
        val text = when (kind) {
            "agent", "agent-readonly" -> three
            "agent-four" -> four
            "agent-reply" -> free
            else -> return null
        }
        return parseDialog(HerdrOutput("w2:p1", loading = false, lines = termLines(text)), System.currentTimeMillis())
    }

    fun show(context: Context, deviceId: String, computer: String, kind: String) {
        val d = dialog(kind) ?: return
        val notice = agentNotice(agent, d, control = kind != "agent-readonly", sdk = Build.VERSION.SDK_INT)
        Android.showAgent(context, deviceId, computer, agent, notice)
    }
}
