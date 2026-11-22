package org.omarchy.flux.core

/** How a notification action acts. [Choice] sends a choice, [Reply] sends the text of the user, and [Open] opens the thread. */
enum class NoticeKind { Choice, Reply, Open }

/** One action of the agent notification. [key] is the number of the choice for a [NoticeKind.Choice], or empty. */
data class NoticeAction(val kind: NoticeKind, val label: String, val key: String)

/**
 * The text of the notification of an agent. [text] is the line of the
 * collapsed notification, and [bigText] is the expanded text with each
 * choice in full.
 */
data class AgentNotice(val title: String, val text: String, val bigText: String, val actions: List<NoticeAction>)

/** The first Android version that asks for the unlock before an action, and that starts an activity from the action. */
const val ANSWER_SDK = 31

/** The longest label of an action, in characters. */
const val ACTION_LABEL_MAX = 24

/** The words that end the text of a notification of a computer with Agent control off. */
const val READ_ONLY = "Read only"

private const val ELLIPSIS = "…"

/** The most choices that get 1 action each. Android shows 3 actions. */
private const val MAX_CHOICE_ACTIONS = 3

/** Cuts [label] at a word end to [max] characters, and adds an ellipsis when it cuts. */
fun cutLabel(label: String, max: Int = ACTION_LABEL_MAX): String {
    val t = label.trim()
    if (t.length <= max) return t
    // The label may end exactly at the limit, so the next character must be a space.
    val head = t.substring(0, max + 1)
    val space = head.lastIndexOf(' ')
    val cut = if (space > 0) head.substring(0, space) else t.substring(0, max)
    return cut.trimEnd(',', ';', ':', '.', ' ') + ELLIPSIS
}

/**
 * The line of a dialog for the notification: the first line above the
 * choices, for example the command, and then the question.
 */
private fun summary(dialog: AgentDialog): String {
    val first = dialog.lines.firstOrNull()?.trim().orEmpty()
    val head = if (first.isEmpty() || first.last() in ".?!") first else "$first."
    return listOf(head, dialog.question.trim()).filter { it.isNotEmpty() }.joinToString(" ")
}

/**
 * Builds the notification of [agent]. [dialog] is the dialog that the last
 * read found, or null. [control] is true when the computer accepts input
 * from this phone. [sdk] is the Android version.
 *
 * A blocked agent with 2 or 3 choices gets 1 action for each choice. A
 * blocked agent with no choices gets Reply. Other agents get no action. With
 * [control] off, the text ends with Read only and the notification has no
 * action. Before [ANSWER_SDK], the actions open the thread and send nothing.
 */
fun agentNotice(agent: HerdrAgent, dialog: AgentDialog?, control: Boolean, sdk: Int): AgentNotice {
    val where = agent.project.ifEmpty { agent.workspace }.ifEmpty { agent.pane }
    if (agent.status != AgentStatus.Blocked) {
        return AgentNotice("${agent.agent} in $where finished", agent.title, agent.title, emptyList())
    }
    val question = dialog?.let(::summary)?.takeIf { it.isNotEmpty() } ?: agent.title
    val numbered = dialog?.choices.orEmpty().joinToString("\n") { "${it.key}. ${it.label}" }
    val suffix = if (control) "" else READ_ONLY
    val text = listOf(question, suffix).filter { it.isNotEmpty() }.joinToString(" ")
    val big = listOf(question, numbered).filter { it.isNotEmpty() }.joinToString("\n").let {
        if (suffix.isEmpty()) it else if (it.isEmpty()) suffix else "$it\n$suffix"
    }
    val actions = ArrayList<NoticeAction>()
    var reply = false
    if (control && dialog != null) {
        val n = dialog.choices.size
        val kind = if (sdk >= ANSWER_SDK) NoticeKind.Choice else NoticeKind.Open
        when {
            n in 2..MAX_CHOICE_ACTIONS -> dialog.choices.forEach { actions += NoticeAction(kind, cutLabel(it.label), it.key) }
            n == 0 -> {
                reply = true
                actions += NoticeAction(if (sdk >= ANSWER_SDK) NoticeKind.Reply else NoticeKind.Open, "Reply", "")
            }
        }
    }
    val title = if (reply) "${agent.agent} in $where asks a question" else "${agent.agent} in $where needs input"
    return AgentNotice(title, text, big, actions)
}
