package org.omarchy.flux.core

/** The most numbered choices that an agent card shows as keys. A question with more choices opens the thread. */
const val NEEDS_MAX_CHOICES = 3

/**
 * The agent card in Needs you. [title] reads `<agent> in <project> needs
 * input`. [question] is the line that asks. [keys] are the numbered choices,
 * or empty when the card has no keys. [dim] is true while the computer is
 * not reachable: the keys show dim and take no tap. [dialogId] is the ID of
 * the dialog that the keys come from.
 */
data class NeedsCard(
    val title: String,
    val question: String,
    val keys: List<AgentChoice>,
    val dim: Boolean,
    val dialogId: String,
)

/**
 * Builds the card of the blocked agent [r] from its last [dialog], or null
 * when no read found a dialog. The keys show only when the computer lets
 * this phone control herdr and the dialog has 1 to [NEEDS_MAX_CHOICES]
 * numbered choices. Else the card shows the question and no keys.
 */
fun needsCard(r: AgentRow, dialog: AgentDialog?): NeedsCard {
    val a = r.agent
    val place = a.project.ifEmpty { a.workspace }
    val title = if (place.isEmpty()) "${a.agent} needs input" else "${a.agent} in $place needs input"
    val question = dialog?.question?.takeIf { it.isNotEmpty() } ?: a.title
    val keys = if (r.control && dialog != null && dialog.choices.size in 1..NEEDS_MAX_CHOICES) dialog.choices else emptyList()
    return NeedsCard(title, question, keys, dim = !r.reachable, dialogId = dialog?.id.orEmpty())
}

/**
 * Sends the choice [key] of a card. It asks [ready] first, then reads the
 * pane again through [verify]. It sends the keys of the new read only when
 * the dialog ID is [dialogId]. Else it sends nothing and calls [open] with
 * the new dialog, or with null when the read failed, so that the thread
 * shows the current choices.
 */
fun answerNeedsKey(
    key: String,
    dialogId: String,
    ready: () -> Boolean,
    verify: (id: String, onSame: (AgentDialog) -> Unit, onChanged: (AgentDialog?) -> Unit) -> Unit,
    send: (List<String>) -> Unit,
    open: (AgentDialog?) -> Unit,
) {
    if (!ready()) {
        open(null)
        return
    }
    verify(
        dialogId,
        { d ->
            val c = d.choices.firstOrNull { it.key == key }
            if (c == null || !ready()) open(d) else send(c.keys)
        },
        { d -> open(d) },
    )
}

/**
 * The text of the empty Needs you place. [working] are the agents that
 * work. With 1 computer it names the computer: `1 agent works on
 * omarchy-xps.` With more it counts the computers.
 */
fun needsEmptyLine(working: List<AgentRow>): String {
    val n = working.size
    if (n == 0) return "No agent works now."
    val computers = working.map { it.computer }.distinct()
    val verb = if (n == 1) "agent works" else "agents work"
    return if (computers.size == 1) "$n $verb on ${computers[0]}." else "$n $verb on ${computers.size} computers."
}

/** True when the computer row shows **Wake**: the computer is not reachable and can wake. */
fun showsWake(d: DeviceUi): Boolean = d.paired && !d.online && d.canWake
