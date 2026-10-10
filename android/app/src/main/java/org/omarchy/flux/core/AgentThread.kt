package org.omarchy.flux.core

/**
 * The thread view of an agent: its output as messages, tool calls, file
 * changes, and prompts, as in a chat. The parser reads the text lines of the
 * output, as [tidyLines] gives them. It knows the transcripts of Claude Code,
 * Codex, and opencode. Lines that it does not know stay as raw terminal lines, so that
 * the view never loses output. The parser has no Android imports, so the JVM
 * tests can load it.
 */

/** A file that an agent changed, with the counts of added and removed lines. */
data class FileChange(val path: String, val added: Int, val removed: Int)

/** One block of the thread of an agent. */
sealed interface ThreadBlock {
    /** Text of the agent. Its lines keep their breaks. */
    data class Message(val text: String) : ThreadBlock

    /**
     * A tool call, for example `Bash(npm test)`: the [name] of the tool, its
     * [args], and the [result] lines under it. [failed] is true when the
     * result starts with an error. [change] is set for a file edit.
     */
    data class Tool(
        val name: String,
        val args: String,
        val result: List<String>,
        val failed: Boolean = false,
        val change: FileChange? = null,
    ) : ThreadBlock

    /** A run of 2 or more file edits, as 1 summary. */
    data class Changes(val files: List<FileChange>) : ThreadBlock {
        val added: Int get() = files.sumOf { it.added }
        val removed: Int get() = files.sumOf { it.removed }
    }

    /** A prompt that the user sent to the agent. */
    data class Prompt(val text: String) : ThreadBlock

    /** Output lines that the parser does not know: the lines from [from] until [to] of the output. */
    data class Raw(val from: Int, val to: Int) : ThreadBlock
}

/**
 * The thread of an agent. [step] is what a working agent does now, for
 * example "Running tests", and [elapsed] is its time as the agent shows it,
 * for example "2:14". [worked] is the time of the last turn of the agent
 * after it finished, for example "6m 12s". Each of these 3 is empty when
 * the output does not show it.
 */
data class AgentThread(
    val blocks: List<ThreadBlock>,
    val step: String = "",
    val elapsed: String = "",
    val worked: String = "",
)

/**
 * The question of a blocked agent, for the dialog of the agent screen and
 * the Inbox. [question] is the line that asks, for example "Do you want to
 * proceed?", or empty. [lines] are the lines above the choices, for example
 * the command that a choice approves. [command] is true when the lines are
 * a shell command.
 */
data class AgentAsk(val question: String, val lines: List<String>, val command: Boolean = false)

/** The bullet of a message or a tool call: ● and ⏺ of Claude Code, • of Codex. */
private val bulletLine = Regex("""^([●⏺•])\s+(.*)$""")

/** A prompt of the user: > in Claude Code, › in Codex. */
private val promptLine = Regex("""^[>›](?:\s+(.*))?$""")

/** A tool call of Claude Code, for example Bash(npm test) or an MCP tool. */
private val toolCall = Regex("""^([A-Za-z][\w.-]*|[\w.-]+ - [\w.-]+ \(MCP\))\((.*)\)\s*$""")

/** A tool call of Codex, for example "Ran npm test" or "Edited src/a.ts (+3 -1)". */
private val codexTool = Regex("""^(Ran|Running|Edited|Added|Deleted|Explored|Exploring|Read|Searched|Listed|Called|Calling|Waited|Updated Plan)\b\s*(.*)$""")

/** The counts at the end of a Codex edit, for example (+3 -1). */
private val codexCounts = Regex("""\s*\(\+(\d+)\s+-(\d+)\)\s*$""")

/** The marks at the start of a result line: ⎿ of Claude Code, └ and │ of Codex. */
private val resultMark = Regex("""^(\s*)([⎿└│])\s*""")

/** The tools of Claude Code and Codex that edit a file. */
private val editTools = setOf("Update", "Write", "Edit", "MultiEdit", "Create", "NotebookEdit", "Edited", "Added", "Deleted")

private val additions = Regex("""(\d+) additions?""")
private val removals = Regex("""(\d+) removals?""")
private val addedLines = Regex("""(?:Added|Wrote) (\d+) lines?""")
private val removedLines = Regex("""[Rr]emoved (\d+) lines?""")

/**
 * The working line of an agent, for example "✻ Running tests… (2:14 · esc
 * to interrupt)" of Claude Code or "• Working (12s • esc to interrupt)" of
 * Codex.
 */
private val workLine = Regex("""^\s*\S{1,2}\s+(.+?)\s*\(([^()]*\bto interrupt\b[^()]*)\)\s*$""")

/** A time in a working line or a finished line, for example 12s, 2m 5s, or 2:14. */
private val timeText = Regex("""\b(\d+h(?: \d+m)?(?: \d+s)?|\d+m(?: \d+s)?|\d+s|\d+:\d{2}(?::\d{2})?)\b""")

/** The line after a finished turn, for example "✻ Worked for 6m 12s" or "─ Worked for 1m 03s ───". */
private val doneLine = Regex("""^[\s\W]*[A-Z][a-z]+ for (\d+h(?: \d+m)?(?: \d+s)?|\d+m(?: \d+s)?|\d+s)\b[\s─━]*$""")

/** A line with only rule characters. */
private val ruleOnly = Regex("""^[\s─━═╌┄╍┈┉\-_]+$""")

/** The first numbered choice of a dialog. */
private val firstChoiceLine = Regex("""^\s*([❯›>]\s*)?1[.)]\s+.+$""")

/** The hints under the input of an agent. */
private val footerWords = listOf(
    "for shortcuts", "shift+tab", "context left", "accept edits", "bypass permissions", "plan mode", "auto-accept",
    "% context", "esc to cancel", "to cycle", "ctrl+", "Press enter",
)

/** How far from the end the working line can be, in lines that are not empty. */
private const val WORK_SCAN_LINES = 12

/** How far above the first choice the dialog can start, in lines. */
private const val DIALOG_SCAN_LINES = 16

private fun isBox(t: String): Boolean = t.startsWith("╭") || t.startsWith("╰") || (t.startsWith("│") && t.endsWith("│") && t.length > 1)

/** A hint line under the input. It is indented by 2 spaces at most, so that a result line does not count. */
private fun isFooter(line: String): Boolean = indent(line) <= 2 && footerWords.any { line.contains(it, ignoreCase = true) }

private fun indent(s: String): Int = s.indexOfFirst { it != ' ' }.let { if (it < 0) s.length else it }

/**
 * Finds the line where the dialog at the end of [lines] starts, or null
 * when the output ends with no dialog. The dialog starts at the rule or the
 * box above its first choice, as in Claude Code. Without one, it starts at
 * the question above the choices, as in Codex. Without a question, it takes
 * the lines directly above the choices.
 */
fun dialogStart(lines: List<String>): Int? {
    if (findChoices(lines).isEmpty()) return null
    val first = (lines.size - 1 downTo 0).firstOrNull { firstChoiceLine.matches(lines[it]) } ?: return null
    val stop = maxOf(0, first - DIALOG_SCAN_LINES)
    val range = first - 1 downTo stop
    // The thread above the dialog ends at a message, a tool call, or a prompt.
    val thread = range.firstOrNull { bulletLine.matches(lines[it]) || promptLine.matches(lines[it]) } ?: -1
    range.firstOrNull { it > thread && lines[it].trim().let { t -> t.isNotEmpty() && (ruleOnly.matches(t) || t.startsWith("╭")) } }?.let { return it }
    range.firstOrNull { it > thread && lines[it].trim().endsWith("?") }?.let { return it }
    var s = first
    while (s > maxOf(stop, thread + 1) && lines[s - 1].isNotBlank()) s--
    return s
}

/**
 * Returns the question of the dialog at the end of [lines], or null when
 * the output ends with no choices. It keeps the [maxLines] lines nearest
 * the choices, because they hold the command that a choice approves. The
 * title of the dialog, for example "Bash command", does not show. After a
 * command title, the command gets a "$ " in front.
 */
fun agentAsk(lines: List<String>, maxLines: Int = 4): AgentAsk? {
    if (isOpencode(lines)) return opencodeAsk(lines, maxLines)
    val start = dialogStart(lines) ?: return null
    val first = (lines.size - 1 downTo start).firstOrNull { firstChoiceLine.matches(lines[it]) } ?: return null
    // The lines of the dialog without rules, box edges, and empty lines. Each keeps its indent and whether a blank line follows it.
    data class Row(val text: String, val indent: Int, val gapAfter: Boolean)
    val rows = ArrayList<Row>()
    for (i in start until first) {
        var t = lines[i].trimEnd()
        val s = t.trim()
        if (s.isEmpty()) {
            if (rows.isNotEmpty()) rows[rows.size - 1] = rows.last().copy(gapAfter = true)
            continue
        }
        if (ruleOnly.matches(s) || s.startsWith("╭") || s.startsWith("╰")) continue
        // The header chips of a question of Claude Code, for example "☐ Tax rate".
        if (s.startsWith("☐") || s.startsWith("☒") || s.startsWith("✔") || s.startsWith("←  ☐")) continue
        if (s.startsWith("│")) t = s.removePrefix("│").removeSuffix("│").trimEnd()
        if (t.isBlank()) continue
        rows += Row(t.trim(), indent(t), gapAfter = false)
    }
    if (rows.isEmpty()) return AgentAsk("", emptyList())
    var question = ""
    var body: List<Row> = rows
    if (body.last().text.endsWith("?")) {
        question = body.last().text
        body = body.dropLast(1)
    } else if (body.first().text.endsWith("?")) {
        question = body.first().text
        body = body.drop(1)
    }
    // A title: the first line, with a blank line under it, and more indented lines after it.
    var command = false
    if (body.size >= 2 && body[0].gapAfter && body[1].indent > body[0].indent) {
        command = body[0].text.endsWith("command", ignoreCase = true)
        body = body.drop(1)
    }
    var text = body.map { it.text }.takeLast(maxLines)
    if (command && text.isNotEmpty() && !text[0].startsWith("$ ")) text = listOf("$ " + text[0]) + text.drop(1)
    if (!command) command = text.firstOrNull()?.startsWith("$ ") == true
    return AgentAsk(question, text, command)
}

/** The counts of added and removed lines in the [result] of an edit tool. */
private fun editCounts(result: List<String>): Pair<Int, Int> {
    val text = result.joinToString("\n")
    val added = additions.find(text)?.groupValues?.get(1)?.toInt() ?: addedLines.find(text)?.groupValues?.get(1)?.toInt() ?: 0
    val removed = removals.find(text)?.groupValues?.get(1)?.toInt() ?: removedLines.find(text)?.groupValues?.get(1)?.toInt() ?: 0
    return added to removed
}

/**
 * Removes the input box of the agent and the hints under it from the end
 * of [lines], until [end]. It returns the new end.
 */
private fun stripInput(lines: List<String>, end: Int): Int {
    var i = end
    var input = false
    while (i > 0) {
        val t = lines[i - 1].trim()
        when {
            t.isEmpty() || ruleOnly.matches(t) -> i--
            isBox(t) -> {
                i--
                input = true
            }
            !input && promptLine.matches(t) -> {
                i--
                input = true
            }
            !input && isFooter(lines[i - 1]) -> i--
            else -> return i
        }
    }
    return i
}

/** Parses the output [lines] of an agent into its thread. */
fun agentThread(lines: List<String>): AgentThread {
    if (isOpencode(lines)) return opencodeThread(lines)
    val dialog = dialogStart(lines)
    var end = dialog ?: stripInput(lines, lines.size)
    // The dialog takes the place of the input, so only the empty lines and the rules above it go.
    while (dialog != null && end > 0 && lines[end - 1].trim().let { it.isEmpty() || ruleOnly.matches(it) }) end--
    var step = ""
    var elapsed = ""
    var worked = ""
    // The working line sits above the input, and a list of tasks can follow it.
    var seen = 0
    var w = end - 1
    while (w >= 0 && seen < WORK_SCAN_LINES) {
        val t = lines[w]
        if (t.isNotBlank()) {
            val m = workLine.matchEntire(t)
            if (m != null) {
                step = m.groupValues[1].trim().removeSuffix("…").removeSuffix("...").trim()
                elapsed = timeText.find(m.groupValues[2])?.value.orEmpty()
                end = w
                while (end > 0 && lines[end - 1].isBlank()) end--
                break
            }
            seen++
        }
        w--
    }
    if (step.isEmpty() && end > 0) {
        doneLine.matchEntire(lines[end - 1].trimEnd())?.let { m ->
            worked = m.groupValues[1]
            end--
            while (end > 0 && lines[end - 1].isBlank()) end--
        }
    }
    return AgentThread(mergeEdits(parseBlocks(lines, end)), step, elapsed, worked)
}

/** Parses the lines until [end] into blocks. */
private fun parseBlocks(lines: List<String>, end: Int): List<ThreadBlock> {
    val blocks = ArrayList<ThreadBlock>()
    var rawFrom = -1
    var rawTo = -1
    fun flushRaw() {
        if (rawFrom >= 0) blocks += ThreadBlock.Raw(rawFrom, rawTo)
        rawFrom = -1
    }
    // The end of a block that starts at [from]: the lines under it that are indented. A blank line
    // belongs to the block only when an indented line follows it.
    fun blockEnd(from: Int): Int {
        var j = from + 1
        var last = from + 1
        while (j < end) {
            val l = lines[j]
            if (l.isBlank()) {
                j++
                continue
            }
            if (indent(l) < 2 || bulletLine.matches(l)) break
            j++
            last = j
        }
        return last
    }
    var i = 0
    while (i < end) {
        val line = lines[i]
        if (line.isBlank()) {
            i++
            continue
        }
        val bullet = bulletLine.matchEntire(line)
        val prompt = if (bullet == null) promptLine.matchEntire(line) else null
        if (bullet == null && prompt == null) {
            if (rawFrom < 0) rawFrom = i
            rawTo = i + 1
            i++
            continue
        }
        flushRaw()
        val to = blockEnd(i)
        val body = lines.subList(i + 1, to)
        if (prompt != null) {
            val text = (listOf(prompt.groupValues[1]) + dedent(body)).joinToString("\n").trim()
            if (text.isNotEmpty()) blocks += ThreadBlock.Prompt(text)
        } else {
            blocks += bulletBlock(bullet!!.groupValues[1], bullet.groupValues[2].trimEnd(), body)
        }
        i = to
    }
    flushRaw()
    return blocks
}

/** Removes the indent that the [lines] share, and keeps the blank lines between them as 1 blank line. */
private fun dedent(lines: List<String>): List<String> {
    val pad = lines.filter { it.isNotBlank() }.minOfOrNull(::indent) ?: 0
    val out = ArrayList<String>()
    for (l in lines) {
        if (l.isBlank()) {
            if (out.isNotEmpty() && out.last().isNotEmpty()) out += ""
        } else {
            out += l.drop(pad).trimEnd()
        }
    }
    while (out.isNotEmpty() && out.last().isEmpty()) out.removeAt(out.size - 1)
    return out
}

/** The result lines under a tool call, without their marks. Each line keeps its indent under the first line. */
private fun resultLines(body: List<String>): List<String> {
    val first = body.firstOrNull { it.isNotBlank() } ?: return emptyList()
    val mark = resultMark.find(first)
    val col = mark?.range?.last?.plus(1) ?: indent(first)
    return dedentFrom(body, col)
}

/** Removes up to [col] spaces from each line, and the blank lines at the ends. */
private fun dedentFrom(lines: List<String>, col: Int): List<String> {
    val out = lines.map { l ->
        val m = resultMark.find(l)
        if (m != null) {
            l.substring(m.range.last + 1).trimEnd()
        } else {
            l.drop(minOf(col, indent(l))).trimEnd()
        }
    }.toMutableList()
    while (out.isNotEmpty() && out.first().isBlank()) out.removeAt(0)
    while (out.isNotEmpty() && out.last().isBlank()) out.removeAt(out.size - 1)
    return out
}

/** A block that starts with a bullet: a tool call or a message. */
private fun bulletBlock(bullet: String, head: String, body: List<String>): ThreadBlock {
    val call = if (bullet == "•") null else toolCall.matchEntire(head)
    if (call != null) {
        val name = call.groupValues[1]
        val args = call.groupValues[2]
        val result = resultLines(body)
        val failed = result.firstOrNull()?.trimStart()?.startsWith("Error") == true
        val change = if (name in editTools && args.isNotBlank()) {
            val (a, r) = editCounts(result)
            FileChange(args.substringBefore(", ").trim(), a, r)
        } else {
            null
        }
        return ThreadBlock.Tool(name, args, result, failed, change)
    }
    val codex = if (bullet == "•") codexTool.matchEntire(head) else null
    val marked = body.firstOrNull { it.isNotBlank() }?.let { resultMark.find(it) } != null
    if (codex != null && (marked || codexCounts.containsMatchIn(head))) {
        val name = codex.groupValues[1]
        var args = codex.groupValues[2]
        var change: FileChange? = null
        val counts = codexCounts.find(args)
        if (name in editTools) {
            val path = args.replace(codexCounts, "").trim()
            change = FileChange(path, counts?.groupValues?.get(1)?.toInt() ?: 0, counts?.groupValues?.get(2)?.toInt() ?: 0)
            args = path
        }
        val result = resultLines(body)
        return ThreadBlock.Tool(name, args, result, failed = false, change = change)
    }
    val text = (listOf(head) + dedent(body)).joinToString("\n").trim()
    return ThreadBlock.Message(text)
}

/** Turns each run of 2 or more file edits into 1 [ThreadBlock.Changes]. The same file shows once, with the sum of its counts. */
private fun mergeEdits(blocks: List<ThreadBlock>): List<ThreadBlock> {
    val out = ArrayList<ThreadBlock>()
    var run = ArrayList<ThreadBlock.Tool>()
    fun flush() {
        if (run.size >= 2) {
            val files = LinkedHashMap<String, FileChange>()
            for (t in run) {
                val c = t.change!!
                files[c.path] = files[c.path]?.let { it.copy(added = it.added + c.added, removed = it.removed + c.removed) } ?: c
            }
            out += ThreadBlock.Changes(files.values.toList())
        } else {
            out += run
        }
        run = ArrayList()
    }
    for (b in blocks) {
        if (b is ThreadBlock.Tool && b.change != null && !b.failed) {
            run += b
        } else {
            flush()
            out += b
        }
    }
    flush()
    return out
}

// ───────────────────────── opencode ─────────────────────────

/** The line after a turn of opencode: the mode, the model, and the time, for example "▣  Build · Big Pickle · 21.2s". */
private val ocFooter = Regex("""^\s*▣\s+\S.*$""")

/** The time at the end of a footer of opencode. */
private val ocTime = Regex("""·\s*(\d+(?:\.\d+)?s|\d+m(?: \d+(?:\.\d+)?s)?|\d+h(?: \d+m)?)\s*$""")

/** A tool line of opencode, for example "→ Read invoice.js", "← Edit invoice.js", or "✱ Grep total". */
private val ocTool = Regex("""^([→←✱⚙◇])\s+([A-Za-z][\w-]*)\s*(.*)$""")

/** A shell command of opencode: "$ node invoice.test.js". */
private val ocShell = Regex("""^\$\s+(.+)$""")

/** A changed line of a diff of opencode: the line number, then + or -. */
private val ocDiffLine = Regex("""^\s*\d+\s+([+-])\s""")

/** A numbered line of a diff of opencode. */
private val ocNumbered = Regex("""^\s*\d+\s""")

/** The options of a tool call of opencode, for example " [replaceAll=false]". */
private val ocOptions = Regex("""\s+\[[^\]]*\]\s*$""")

/** The scroll bar at the right edge of a dialog of opencode. */
private val ocScrollBar = Regex("""\s+[█▀▄▌▐░▒▓]\s*$""")

/** The line of opencode that tells how long the model thought. */
private val ocThought = Regex("""^\+\s+Thought:\s+\S+$""")

/** The first choice of a question of opencode. */
private val ocChoiceStart = Regex("""^1[.)]\s+.+$""")

/** The first line of a permission dialog of opencode. */
private const val OC_ASK = "△ Permission required"

/** The text of the panel line [line] of opencode without its bar, or null when it is not a panel line. */
private fun ocPanel(line: String): String? {
    val t = line.trimStart()
    if (!t.startsWith("┃")) return null
    val c = t.removePrefix("┃")
    return if (c.startsWith("  ")) c.substring(2) else c.trimStart()
}

/**
 * True when [lines] come from opencode: they have the line after a turn,
 * the status line at the bottom, a permission dialog, or a question.
 */
fun isOpencode(lines: List<String>): Boolean =
    lines.takeLast(6).any { it.contains("ctrl+p commands") } ||
        lines.any { l -> ocFooter.matches(l) || ocPanel(l)?.let { c -> c.startsWith(OC_ASK) || ocQuestionHint.all { c.contains(it) } } == true }

/**
 * The end of the thread of opencode, the start of its dialog or null, and
 * whether it works now. [question] is true when the dialog is a question of
 * the agent, not a permission.
 */
private data class OcEnd(val end: Int, val dialog: Int?, val working: Boolean, val question: Boolean = false)

/** The hint under the choices of a question of opencode. */
private val ocQuestionHint = listOf("↑↓ select", "enter submit")

/** The first line of a question of opencode that the user answered. */
private const val OC_QUESTIONS = "# Questions"

/**
 * Finds the end of the thread of opencode: the status line, the input box,
 * and the permission dialog at the bottom do not belong to it.
 */
private fun opencodeEnd(lines: List<String>): OcEnd {
    var end = lines.size
    var working = false
    while (end > 0 && lines[end - 1].isBlank()) end--
    if (end > 0 && (lines[end - 1].contains("ctrl+p commands") || lines[end - 1].contains("esc interrupt"))) {
        working = lines[end - 1].contains("esc interrupt")
        end--
    }
    while (end > 0 && (lines[end - 1].isBlank() || lines[end - 1].trimStart().startsWith("╹"))) end--
    // A permission dialog or a question takes the place of the input box.
    var i = end
    while (i > 0 && ocPanel(lines[i - 1]) != null) i--
    val ask = (i until end).firstOrNull { ocPanel(lines[it])?.startsWith(OC_ASK) == true }
    val question = ask == null && (i until end).any { k -> ocPanel(lines[k])?.let { c -> ocQuestionHint.any { c.contains(it) } } == true }
    if (ask != null || question) {
        var e = ask ?: i
        // The tool call that waits for the answer and the line of the turn are in the dialog too.
        while (e > 0) {
            val l = lines[e - 1]
            val t = l.trim()
            val pending = ocPanel(l) == null && (t.startsWith("$ ") || t.startsWith("← ") || t.startsWith("→ Asked") || ocFooter.matches(l))
            if (t.isEmpty() || ocPanel(l)?.isBlank() == true || pending) e-- else break
        }
        return OcEnd(e, ask ?: i, working, question)
    }
    // The input box: empty lines and the line with the mode and the model.
    while (end > 0) {
        val c = ocPanel(lines[end - 1]) ?: break
        if (c.isBlank() || c.contains(" · ")) end-- else break
    }
    return OcEnd(end, null, working)
}

/** Parses the output [lines] of opencode into its thread. */
private fun opencodeThread(lines: List<String>): AgentThread {
    var (end, _, working) = opencodeEnd(lines)
    var worked = ""
    while (end > 0 && lines[end - 1].isBlank()) end--
    if (end > 0 && ocFooter.matches(lines[end - 1])) {
        if (!working) worked = ocTime.find(lines[end - 1])?.groupValues?.get(1).orEmpty()
        end--
    }
    val blocks = ArrayList<ThreadBlock>()
    val message = ArrayList<String>()
    fun flushMessage() {
        while (message.isNotEmpty() && message.last().isEmpty()) message.removeAt(message.size - 1)
        // The lines keep their indent under the first line, for example the lines of code in a message.
        if (message.isNotEmpty()) blocks += ThreadBlock.Message(dedent(message).joinToString("\n"))
        message.clear()
    }
    var i = 0
    while (i < end) {
        val line = lines[i]
        val panel = ocPanel(line)
        if (panel != null) {
            flushMessage()
            var j = i
            while (j < end && ocPanel(lines[j]) != null) j++
            blocks += opencodePanel(lines.subList(i, j).map { ocPanel(it)!! })
            i = j
            continue
        }
        val t = line.trim()
        when {
            t.isEmpty() -> if (message.isNotEmpty()) message += ""
            ocFooter.matches(line) -> flushMessage()
            ocShell.matches(t) || ocTool.matches(t) -> {
                flushMessage()
                blocks += opencodeTool(t, emptyList())
            }
            // The time that the model thought, for example "+ Thought: 37.7s", is not a message.
            ocThought.matches(t) -> Unit
            t.startsWith("···") -> {
                flushMessage()
                blocks += ThreadBlock.Raw(i, i + 1)
            }
            else -> message += line
        }
        i++
    }
    flushMessage()
    return AgentThread(mergeEdits(blocks), if (working) "Working" else "", "", worked)
}

/**
 * The blocks of a panel of opencode: a prompt of the user, then tool calls
 * with their output. A question that the user answered shows as the
 * question of the agent and the answer of the user.
 */
private fun opencodePanel(content: List<String>): List<ThreadBlock> {
    val out = ArrayList<ThreadBlock>()
    val rows = content.map { it.trim() }.filter { it.isNotEmpty() }
    if (rows.firstOrNull() == OC_QUESTIONS) {
        // Each line that ends with a question mark starts a question. The lines after it are the answer.
        var q: String? = null
        val answer = ArrayList<String>()
        fun flush() {
            q?.let { out += ThreadBlock.Message(it) }
            if (answer.isNotEmpty()) out += ThreadBlock.Prompt(answer.joinToString("\n"))
            answer.clear()
        }
        for (r in rows.drop(1)) {
            if (r.endsWith("?")) {
                flush()
                q = r
            } else {
                answer += r
            }
        }
        flush()
        return out
    }
    var k = 0
    val prompt = ArrayList<String>()
    while (k < content.size && !isOcMarker(content[k])) prompt += content[k++]
    val text = prompt.map { it.trim() }.dropWhile { it.isEmpty() }.dropLastWhile { it.isEmpty() }.joinToString("\n")
    if (text.isNotEmpty()) out += ThreadBlock.Prompt(text)
    while (k < content.size) {
        val head = content[k++].trim()
        val body = ArrayList<String>()
        while (k < content.size && !isOcMarker(content[k])) body += content[k++]
        out += opencodeTool(head, body)
    }
    return out
}

/** True when a line of a panel starts a tool call. */
private fun isOcMarker(c: String): Boolean = c.isNotEmpty() && !c.startsWith(" ") && (ocShell.matches(c) || ocTool.matches(c))

/** A tool call of opencode from its [head] line and the [body] lines under it. */
private fun opencodeTool(head: String, body: List<String>): ThreadBlock.Tool {
    val result = dedent(body)
    ocShell.matchEntire(head)?.let { return ThreadBlock.Tool("Bash", it.groupValues[1], result) }
    val m = ocTool.matchEntire(head) ?: return ThreadBlock.Tool(head, "", result)
    val name = m.groupValues[2]
    val args = m.groupValues[3].replace(ocOptions, "").trim()
    val failed = result.firstOrNull()?.trimStart()?.startsWith("Error") == true
    val change = if (m.groupValues[1] == "←" && args.isNotEmpty()) {
        var added = result.count { ocDiffLine.find(it)?.groupValues?.get(1) == "+" }
        val removed = result.count { ocDiffLine.find(it)?.groupValues?.get(1) == "-" }
        // A new file shows its lines with numbers and no mark.
        if (added == 0 && removed == 0 && name == "Write") added = result.count { ocNumbered.containsMatchIn(it) }
        FileChange(args, added, removed)
    } else {
        null
    }
    return ThreadBlock.Tool(name, args, result, failed, change)
}

/**
 * The question of the permission dialog of opencode, or null when the
 * output has no dialog. The title of the dialog, for example "# Shell
 * command", does not show. A shell command shows as the command. An edit
 * shows the file, then the first [maxLines] lines of its diff.
 */
private fun opencodeAsk(lines: List<String>, maxLines: Int): AgentAsk? {
    val end = opencodeEnd(lines)
    val ask = end.dialog ?: return null
    if (end.question) {
        // The question is the text above the first choice. The choices show as buttons.
        val text = ArrayList<String>()
        for (l in lines.subList(ask, lines.size)) {
            val c = ocPanel(l)?.trim() ?: continue
            if (ocChoiceStart.matches(c)) break
            if (c.isNotEmpty()) text += c
        }
        return AgentAsk(text.joinToString(" "), emptyList())
    }
    val rows = ArrayList<String>()
    for (l in lines.subList(ask + 1, lines.size)) {
        val c = ocPanel(l) ?: break
        if (c.contains("⇆") || c.contains("enter confirm")) break
        rows += c.replace(ocScrollBar, "").trimEnd()
    }
    val content = dedent(rows)
    if (content.isEmpty()) return AgentAsk(OC_ASK.removePrefix("△ "), emptyList())
    val title = content.first().trim()
    val body = content.drop(1).dropWhile { it.isBlank() }.filter { it.isNotBlank() }
    val question = OC_ASK.removePrefix("△ ")
    return when {
        title.startsWith("#") && body.firstOrNull()?.startsWith("$ ") == true -> AgentAsk(question, body.take(maxLines), command = true)
        title.startsWith("→ ") || title.startsWith("← ") -> AgentAsk(question, (listOf(title.drop(2)) + body).take(maxLines))
        else -> AgentAsk(question, (listOf(title) + body).take(maxLines))
    }
}

/** The kind of a line of a diff, for its color. */
enum class DiffLineKind { Hunk, Added, Removed, Context }

/** A line of a diff. */
data class DiffLine(val text: String, val kind: DiffLineKind)

/** A file in a diff, with its counts and lines. */
data class DiffFile(val path: String, val added: Int, val removed: Int, val lines: List<DiffLine>)

/**
 * Parses the review diff that fluxd sends, a `git diff` with a list of the
 * changed files above it, into files. The lines above the first file and
 * the headers of each file do not show.
 */
fun parseDiff(lines: List<String>): List<DiffFile> {
    val files = ArrayList<DiffFile>()
    var path: String? = null
    var added = 0
    var removed = 0
    var body = ArrayList<DiffLine>()
    var inHunk = false
    fun flush() {
        // fluxd puts an empty line above each new file. It is not a line of the file before it.
        while (body.lastOrNull()?.let { it.kind == DiffLineKind.Context && it.text.isBlank() } == true) body.removeAt(body.size - 1)
        path?.let { files += DiffFile(it, added, removed, body) }
        path = null
        added = 0
        removed = 0
        body = ArrayList()
        inHunk = false
    }
    for (l in lines) {
        if (l.startsWith("diff --git ")) {
            flush()
            path = l.substringAfter(" b/", l.removePrefix("diff --git ").substringAfter("a/")).trim()
            continue
        }
        if (path == null) continue
        when {
            l.startsWith("@@") -> {
                inHunk = true
                body += DiffLine(l, DiffLineKind.Hunk)
            }
            !inHunk -> {
                // A new file of fluxd has no hunk. Its lines start with + at once.
                if (l.startsWith("+") && !l.startsWith("+++")) {
                    inHunk = true
                    added++
                    body += DiffLine(l, DiffLineKind.Added)
                } else if (l == "Binary file" || l.startsWith("The new file is larger")) {
                    body += DiffLine(l, DiffLineKind.Context)
                }
            }
            l.startsWith("+") -> {
                added++
                body += DiffLine(l, DiffLineKind.Added)
            }
            l.startsWith("-") -> {
                removed++
                body += DiffLine(l, DiffLineKind.Removed)
            }
            else -> body += DiffLine(l, DiffLineKind.Context)
        }
    }
    flush()
    // fluxd adds an empty line at the end of each new file.
    return files.map { f -> if (f.lines.lastOrNull()?.text == "+") f.copy(added = f.added - 1, lines = f.lines.dropLast(1)) else f }
}
