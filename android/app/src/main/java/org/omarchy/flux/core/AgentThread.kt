package org.omarchy.flux.core

/**
 * The thread view of an agent: its output as messages, tool calls, file
 * changes, and prompts, as in a chat. The parser reads the text lines of the
 * output, as [tidyLines] gives them. It knows the transcripts of Claude Code
 * and Codex. Lines that it does not know stay as raw terminal lines, so that
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
