import Foundation

// The thread view of an agent: its output as messages, tool calls, file
// changes, and prompts, as in a chat. The parser reads the text lines of the
// output, as `TermText.tidy` gives them. It knows the transcripts of Claude
// Code and Codex. Lines that it does not know stay as raw terminal lines, so
// that the view never loses output. This is a port of AgentThread.kt of the
// Android app, so both apps show the same thread.

/// A file that an agent changed, with the counts of added and removed lines.
public struct FileChange: Sendable, Hashable {
    public var path: String
    public var added: Int
    public var removed: Int

    public init(_ path: String, _ added: Int, _ removed: Int) {
        self.path = path
        self.added = added
        self.removed = removed
    }
}

/// A tool call, for example `Bash(npm test)`: the `name` of the tool, its
/// `args`, and the `result` lines under it. `failed` is true when the result
/// starts with an error. `change` is set for a file edit.
public struct ThreadTool: Sendable, Hashable {
    public var name: String
    public var args: String
    public var result: [String]
    public var failed: Bool
    public var change: FileChange?

    public init(_ name: String, _ args: String, _ result: [String], failed: Bool = false, change: FileChange? = nil) {
        self.name = name
        self.args = args
        self.result = result
        self.failed = failed
        self.change = change
    }
}

/// A run of 2 or more file edits, as 1 summary.
public struct ThreadChanges: Sendable, Hashable {
    public var files: [FileChange]

    public init(_ files: [FileChange]) { self.files = files }

    public var added: Int { files.reduce(0) { $0 + $1.added } }
    public var removed: Int { files.reduce(0) { $0 + $1.removed } }
}

/// One block of the thread of an agent.
public enum ThreadBlock: Sendable, Hashable {
    /// Text of the agent. Its lines keep their breaks.
    case message(String)
    case tool(ThreadTool)
    case changes(ThreadChanges)
    /// A prompt that the user sent to the agent.
    case prompt(String)
    /// Output lines that the parser does not know: the lines from `from` until `to` of the output.
    case raw(from: Int, to: Int)
}

/// The thread of an agent. `step` is what a working agent does now, for
/// example "Running tests", and `elapsed` is its time as the agent shows
/// it, for example "2:14". `worked` is the time of the last turn of the
/// agent after it finished, for example "6m 12s". Each of these 3 is empty
/// when the output does not show it.
public struct AgentThread: Sendable, Hashable {
    public var blocks: [ThreadBlock]
    public var step: String
    public var elapsed: String
    public var worked: String

    public init(_ blocks: [ThreadBlock], step: String = "", elapsed: String = "", worked: String = "") {
        self.blocks = blocks
        self.step = step
        self.elapsed = elapsed
        self.worked = worked
    }
}

/// The question of a blocked agent, for the dialog of the agent screen and
/// the Inbox. `question` is the line that asks, for example "Do you want to
/// proceed?", or empty. `lines` are the lines above the choices, for
/// example the command that a choice approves. `command` is true when the
/// lines are a shell command.
public struct AgentAsk: Sendable, Hashable {
    public var question: String
    public var lines: [String]
    public var command: Bool

    public init(_ question: String, _ lines: [String], command: Bool = false) {
        self.question = question
        self.lines = lines
        self.command = command
    }
}

/// The kind of a line of a diff, for its color.
public enum DiffLineKind: Sendable, Hashable {
    case hunk, added, removed, context
}

/// A line of a diff.
public struct DiffLine: Sendable, Hashable {
    public var text: String
    public var kind: DiffLineKind

    public init(_ text: String, _ kind: DiffLineKind) {
        self.text = text
        self.kind = kind
    }
}

/// A file in a diff, with its counts and lines.
public struct DiffFile: Sendable, Hashable {
    public var path: String
    public var added: Int
    public var removed: Int
    public var lines: [DiffLine]

    public init(_ path: String, added: Int, removed: Int, lines: [DiffLine]) {
        self.path = path
        self.added = added
        self.removed = removed
        self.lines = lines
    }
}

// MARK: Patterns

/// A regular expression with the ASCII classes of Kotlin. ICU gives \s, \w,
/// \d, and \b a Unicode meaning, so the patterns spell the classes out.
struct ThreadPattern: @unchecked Sendable {
    let re: NSRegularExpression

    init(_ pattern: String) {
        re = try! NSRegularExpression(pattern: pattern)
    }

    /// The groups of a match of the whole text, or nil. Group 0 is the whole
    /// text. A group that takes no part in the match is empty.
    func whole(_ s: String) -> [String]? {
        let range = NSRange(s.startIndex..., in: s)
        guard let m = re.firstMatch(in: s, range: range), m.range == range else { return nil }
        return groups(m, s)
    }

    func matches(_ s: String) -> Bool { whole(s) != nil }

    /// The first match in the text: its range and its groups.
    func first(_ s: String) -> (range: Range<String.Index>, groups: [String])? {
        guard let m = re.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)), let r = Range(m.range, in: s) else { return nil }
        return (r, groups(m, s))
    }

    func contains(_ s: String) -> Bool { first(s) != nil }

    /// The text with each match replaced by `with`.
    func replace(_ s: String, with: String) -> String {
        re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: NSRegularExpression.escapedTemplate(for: with))
    }

    private func groups(_ m: NSTextCheckingResult, _ s: String) -> [String] {
        (0..<m.numberOfRanges).map { i in Range(m.range(at: i), in: s).map { String(s[$0]) } ?? "" }
    }
}

/// The whitespace of Kotlin's \s, and its complement.
private let sp = #"[ \t\n\x0B\f\r]"#
private let nsp = #"[^ \t\n\x0B\f\r]"#
/// The word characters of Kotlin's \w, and the word boundaries before and after a word.
private let wordStart = #"(?<![A-Za-z0-9_])"#
private let wordEnd = #"(?![A-Za-z0-9_])"#
/// A time: 12s, 2m 5s, 1h 2m, or 2:14.
private let time = #"[0-9]+h(?: [0-9]+m)?(?: [0-9]+s)?|[0-9]+m(?: [0-9]+s)?|[0-9]+s"#

/// The bullet of a message or a tool call: ● and ⏺ of Claude Code, • of Codex.
private let bulletLine = ThreadPattern("^([●⏺•])\(sp)+(.*)$")
/// A prompt of the user: > in Claude Code, › in Codex.
private let promptLine = ThreadPattern("^[>›](?:\(sp)+(.*))?$")
/// A tool call of Claude Code, for example Bash(npm test) or an MCP tool.
private let toolCall = ThreadPattern(#"^([A-Za-z][A-Za-z0-9_.-]*|[A-Za-z0-9_.-]+ - [A-Za-z0-9_.-]+ \(MCP\))\((.*)\)"# + "\(sp)*$")
/// A tool call of Codex, for example "Ran npm test" or "Edited src/a.ts (+3 -1)".
private let codexTool = ThreadPattern(
    "^(Ran|Running|Edited|Added|Deleted|Explored|Exploring|Read|Searched|Listed|Called|Calling|Waited|Updated Plan)\(wordEnd)\(sp)*(.*)$")
/// The counts at the end of a Codex edit, for example (+3 -1).
private let codexCounts = ThreadPattern("\(sp)*" + #"\(\+([0-9]+)"# + "\(sp)+" + #"-([0-9]+)\)"# + "\(sp)*$")
/// The marks at the start of a result line: ⎿ of Claude Code, └ and │ of Codex.
private let resultMark = ThreadPattern("^(\(sp)*)([⎿└│])\(sp)*")

/// The tools of Claude Code and Codex that edit a file.
private let editTools: Set<String> = ["Update", "Write", "Edit", "MultiEdit", "Create", "NotebookEdit", "Edited", "Added", "Deleted"]

private let additions = ThreadPattern("([0-9]+) additions?")
private let removals = ThreadPattern("([0-9]+) removals?")
private let addedLines = ThreadPattern("(?:Added|Wrote) ([0-9]+) lines?")
private let removedLines = ThreadPattern("[Rr]emoved ([0-9]+) lines?")

/// The working line of an agent, for example "✻ Running tests… (2:14 · esc
/// to interrupt)" of Claude Code or "• Working (12s • esc to interrupt)" of
/// Codex.
private let workLine = ThreadPattern(
    "^\(sp)*\(nsp){1,2}\(sp)+(.+?)\(sp)*" + #"\(([^()]*"# + "\(wordStart)to interrupt\(wordEnd)" + #"[^()]*)\)"# + "\(sp)*$")
/// A time in a working line or a finished line, for example 12s, 2m 5s, or 2:14.
private let timeText = ThreadPattern("\(wordStart)(\(time)|[0-9]+:[0-9]{2}(?::[0-9]{2})?)\(wordEnd)")
/// The line after a finished turn, for example "✻ Worked for 6m 12s" or "─ Worked for 1m 03s ───".
private let doneLine = ThreadPattern("^[^A-Za-z0-9_]*[A-Z][a-z]+ for (\(time))\(wordEnd)[ \t\n\u{0B}\u{0C}\r─━]*$")
/// A line with only rule characters.
private let ruleOnly = ThreadPattern(#"^[ \t\n\x0B\f\r─━═╌┄╍┈┉\-_]+$"#)
/// The first numbered choice of a dialog.
private let firstChoiceLine = ThreadPattern("^\(sp)*([❯›>]\(sp)*)?1[.)]\(sp)+.+$")

/// The hints under the input of an agent.
private let footerWords = [
    "for shortcuts", "shift+tab", "context left", "accept edits", "bypass permissions", "plan mode", "auto-accept",
    "% context", "esc to cancel", "to cycle", "ctrl+", "press enter",
]

/// How far from the end the working line can be, in lines that are not empty.
private let workScanLines = 12
/// How far above the first choice the dialog can start, in lines.
private let dialogScanLines = 16

// MARK: Text helpers with the meaning of Kotlin

private extension String {
    /// The text without whitespace at the start and the end.
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The text without whitespace at the end.
    var trimmedEnd: String {
        var s = Substring(self)
        while let c = s.last, c.unicodeScalars.allSatisfy({ CharacterSet.whitespacesAndNewlines.contains($0) }) { s = s.dropLast() }
        return String(s)
    }

    /// True when the text is empty or has only whitespace.
    var isBlank: Bool { trimmed.isEmpty }

    /// The number of blanks at the start, or the length of a text of blanks.
    var indent: Int { prefix(while: { $0 == " " }).count }

    /// The text after the first `delimiter`, or `missing` without it.
    func after(_ delimiter: String, or missing: String) -> String {
        guard let r = range(of: delimiter) else { return missing }
        return String(self[r.upperBound...])
    }

    /// The text before the first `delimiter`, or the whole text without it.
    func before(_ delimiter: String) -> String {
        guard let r = range(of: delimiter) else { return self }
        return String(self[..<r.lowerBound])
    }
}

private func isBox(_ t: String) -> Bool {
    t.hasPrefix("╭") || t.hasPrefix("╰") || (t.hasPrefix("│") && t.hasSuffix("│") && t.count > 1)
}

/// A hint line under the input. It is indented by 2 spaces at most, so that a result line does not count.
private func isFooter(_ line: String) -> Bool {
    let lower = line.lowercased()
    return line.indent <= 2 && footerWords.contains { lower.contains($0) }
}

// MARK: Dialog

extension AgentAsk {
    /// Finds the line where the dialog at the end of `lines` starts, or nil
    /// when the output ends with no dialog. The dialog starts at the rule or
    /// the box above its first choice, as in Claude Code. Without one, it
    /// starts at the question above the choices, as in Codex. Without a
    /// question, it takes the lines directly above the choices.
    public static func dialogStart(_ lines: [String]) -> Int? {
        if AgentChoice.find(lines).isEmpty { return nil }
        guard let first = lines.indices.reversed().first(where: { firstChoiceLine.matches(lines[$0]) }) else { return nil }
        let stop = max(0, first - dialogScanLines)
        let range = stride(from: first - 1, through: stop, by: -1)
        // The thread above the dialog ends at a message, a tool call, or a prompt.
        let thread = range.first { bulletLine.matches(lines[$0]) || promptLine.matches(lines[$0]) } ?? -1
        if let rule = range.first(where: { i in
            let t = lines[i].trimmed
            return i > thread && !t.isEmpty && (ruleOnly.matches(t) || t.hasPrefix("╭"))
        }) { return rule }
        if let ask = range.first(where: { $0 > thread && lines[$0].trimmed.hasSuffix("?") }) { return ask }
        var s = first
        while s > max(stop, thread + 1) && !lines[s - 1].isBlank { s -= 1 }
        return s
    }

    /// Returns the question of the dialog at the end of `lines`, or nil
    /// when the output ends with no choices. It keeps the `maxLines` lines
    /// nearest the choices, because they hold the command that a choice
    /// approves. The title of the dialog, for example "Bash command", does
    /// not show. After a command title, the command gets a "$ " in front.
    public static func find(_ lines: [String], maxLines: Int = 4) -> AgentAsk? {
        guard let start = dialogStart(lines) else { return nil }
        guard let first = stride(from: lines.count - 1, through: start, by: -1).first(where: { firstChoiceLine.matches(lines[$0]) }) else { return nil }
        // The lines of the dialog without rules, box edges, and empty lines. Each keeps its indent and whether a blank line follows it.
        struct Row {
            var text: String
            var indent: Int
            var gapAfter: Bool
        }
        var rows: [Row] = []
        for i in start..<first {
            var t = lines[i].trimmedEnd
            let s = t.trimmed
            if s.isEmpty {
                if !rows.isEmpty { rows[rows.count - 1].gapAfter = true }
                continue
            }
            if ruleOnly.matches(s) || s.hasPrefix("╭") || s.hasPrefix("╰") { continue }
            if s.hasPrefix("│") {
                var inner = Substring(s).dropFirst()
                if inner.hasSuffix("│") { inner = inner.dropLast() }
                t = String(inner).trimmedEnd
            }
            if t.isBlank { continue }
            rows.append(Row(text: t.trimmed, indent: t.indent, gapAfter: false))
        }
        if rows.isEmpty { return AgentAsk("", []) }
        var question = ""
        var body = rows
        if let last = body.last, last.text.hasSuffix("?") {
            question = last.text
            body.removeLast()
        } else if let firstRow = body.first, firstRow.text.hasSuffix("?") {
            question = firstRow.text
            body.removeFirst()
        }
        // A title: the first line, with a blank line under it, and more indented lines after it.
        var command = false
        if body.count >= 2 && body[0].gapAfter && body[1].indent > body[0].indent {
            command = body[0].text.lowercased().hasSuffix("command")
            body.removeFirst()
        }
        var text = Array(body.map(\.text).suffix(max(0, maxLines)))
        if command, let head = text.first, !head.hasPrefix("$ ") { text[0] = "$ " + head }
        if !command { command = text.first?.hasPrefix("$ ") == true }
        return AgentAsk(question, text, command: command)
    }
}

// MARK: Thread

extension AgentThread {
    /// Parses the output `lines` of an agent into its thread. The input is
    /// the plain text of each line: `HerdrOutput.lines.map(\.text)`.
    public static func parse(_ lines: [String]) -> AgentThread {
        let dialog = AgentAsk.dialogStart(lines)
        var end = dialog ?? stripInput(lines, end: lines.count)
        // The dialog takes the place of the input, so only the empty lines and the rules above it go.
        while dialog != nil && end > 0 && { let t = lines[end - 1].trimmed; return t.isEmpty || ruleOnly.matches(t) }() { end -= 1 }
        var step = ""
        var elapsed = ""
        var worked = ""
        // The working line sits above the input, and a list of tasks can follow it.
        var seen = 0
        var w = end - 1
        while w >= 0 && seen < workScanLines {
            let t = lines[w]
            if !t.isBlank {
                if let m = workLine.whole(t) {
                    var s = m[1].trimmed
                    if s.hasSuffix("…") { s.removeLast() }
                    if s.hasSuffix("...") { s.removeLast(3) }
                    step = s.trimmed
                    elapsed = timeText.first(m[2])?.groups[0] ?? ""
                    end = w
                    while end > 0 && lines[end - 1].isBlank { end -= 1 }
                    break
                }
                seen += 1
            }
            w -= 1
        }
        if step.isEmpty && end > 0, let m = doneLine.whole(lines[end - 1].trimmedEnd) {
            worked = m[1]
            end -= 1
            while end > 0 && lines[end - 1].isBlank { end -= 1 }
        }
        return AgentThread(mergeEdits(parseBlocks(lines, end: end)), step: step, elapsed: elapsed, worked: worked)
    }

    /// Removes the input box of the agent and the hints under it from the
    /// end of `lines`, until `end`. It returns the new end.
    static func stripInput(_ lines: [String], end: Int) -> Int {
        var i = end
        var input = false
        while i > 0 {
            let t = lines[i - 1].trimmed
            if t.isEmpty || ruleOnly.matches(t) {
                i -= 1
            } else if isBox(t) {
                i -= 1
                input = true
            } else if !input && promptLine.matches(t) {
                i -= 1
                input = true
            } else if !input && isFooter(lines[i - 1]) {
                i -= 1
            } else {
                return i
            }
        }
        return i
    }

    /// Parses the lines until `end` into blocks.
    static func parseBlocks(_ lines: [String], end: Int) -> [ThreadBlock] {
        var blocks: [ThreadBlock] = []
        var rawFrom = -1
        var rawTo = -1
        func flushRaw() {
            if rawFrom >= 0 { blocks.append(.raw(from: rawFrom, to: rawTo)) }
            rawFrom = -1
        }
        // The end of a block that starts at `from`: the lines under it that are indented. A blank line
        // belongs to the block only when an indented line follows it.
        func blockEnd(_ from: Int) -> Int {
            var j = from + 1
            var last = from + 1
            while j < end {
                let l = lines[j]
                if l.isBlank {
                    j += 1
                    continue
                }
                if l.indent < 2 || bulletLine.matches(l) { break }
                j += 1
                last = j
            }
            return last
        }
        var i = 0
        while i < end {
            let line = lines[i]
            if line.isBlank {
                i += 1
                continue
            }
            let bullet = bulletLine.whole(line)
            let prompt = bullet == nil ? promptLine.whole(line) : nil
            if bullet == nil && prompt == nil {
                if rawFrom < 0 { rawFrom = i }
                rawTo = i + 1
                i += 1
                continue
            }
            flushRaw()
            let to = blockEnd(i)
            let body = Array(lines[(i + 1)..<to])
            if let prompt {
                let text = ([prompt[1]] + dedent(body)).joined(separator: "\n").trimmed
                if !text.isEmpty { blocks.append(.prompt(text)) }
            } else if let bullet {
                blocks.append(bulletBlock(bullet[1], bullet[2].trimmedEnd, body))
            }
            i = to
        }
        flushRaw()
        return blocks
    }

    /// Removes the indent that the `lines` share, and keeps the blank lines between them as 1 blank line.
    static func dedent(_ lines: [String]) -> [String] {
        let pad = lines.filter { !$0.isBlank }.map(\.indent).min() ?? 0
        var out: [String] = []
        for l in lines {
            if l.isBlank {
                if let last = out.last, !last.isEmpty { out.append("") }
            } else {
                out.append(String(l.dropFirst(pad)).trimmedEnd)
            }
        }
        while out.last?.isEmpty == true { out.removeLast() }
        return out
    }

    /// The result lines under a tool call, without their marks. Each line keeps its indent under the first line.
    static func resultLines(_ body: [String]) -> [String] {
        guard let first = body.first(where: { !$0.isBlank }) else { return [] }
        let col: Int
        if let m = resultMark.first(first) {
            col = first.distance(from: first.startIndex, to: m.range.upperBound)
        } else {
            col = first.indent
        }
        return dedent(body, from: col)
    }

    /// Removes up to `col` spaces from each line, and the blank lines at the ends.
    static func dedent(_ lines: [String], from col: Int) -> [String] {
        var out = lines.map { l -> String in
            if let m = resultMark.first(l) { return String(l[m.range.upperBound...]).trimmedEnd }
            return String(l.dropFirst(min(col, l.indent))).trimmedEnd
        }
        while out.first?.isBlank == true { out.removeFirst() }
        while out.last?.isBlank == true { out.removeLast() }
        return out
    }

    /// The counts of added and removed lines in the `result` of an edit tool.
    static func editCounts(_ result: [String]) -> (Int, Int) {
        let text = result.joined(separator: "\n")
        let added = (additions.first(text) ?? addedLines.first(text)).flatMap { Int($0.groups[1]) } ?? 0
        let removed = (removals.first(text) ?? removedLines.first(text)).flatMap { Int($0.groups[1]) } ?? 0
        return (added, removed)
    }

    /// A block that starts with a bullet: a tool call or a message.
    static func bulletBlock(_ bullet: String, _ head: String, _ body: [String]) -> ThreadBlock {
        if bullet != "•", let call = toolCall.whole(head) {
            let name = call[1]
            let args = call[2]
            let result = resultLines(body)
            let failed = result.first?.drop(while: { $0.isWhitespace }).hasPrefix("Error") == true
            var change: FileChange?
            if editTools.contains(name) && !args.isBlank {
                let (a, r) = editCounts(result)
                change = FileChange(args.before(", ").trimmed, a, r)
            }
            return .tool(ThreadTool(name, args, result, failed: failed, change: change))
        }
        let codex = bullet == "•" ? codexTool.whole(head) : nil
        let marked = body.first(where: { !$0.isBlank }).map { resultMark.contains($0) } ?? false
        if let codex, marked || codexCounts.contains(head) {
            let name = codex[1]
            var args = codex[2]
            var change: FileChange?
            let counts = codexCounts.first(args)
            if editTools.contains(name) {
                let path = codexCounts.replace(args, with: "").trimmed
                change = FileChange(path, counts.flatMap { Int($0.groups[1]) } ?? 0, counts.flatMap { Int($0.groups[2]) } ?? 0)
                args = path
            }
            return .tool(ThreadTool(name, args, resultLines(body), failed: false, change: change))
        }
        return .message(([head] + dedent(body)).joined(separator: "\n").trimmed)
    }

    /// Turns each run of 2 or more file edits into 1 `ThreadBlock.changes`. The same file shows once, with the sum of its counts.
    static func mergeEdits(_ blocks: [ThreadBlock]) -> [ThreadBlock] {
        var out: [ThreadBlock] = []
        var run: [ThreadTool] = []
        func flush() {
            if run.count >= 2 {
                var files: [FileChange] = []
                for t in run {
                    guard let c = t.change else { continue }
                    if let i = files.firstIndex(where: { $0.path == c.path }) {
                        files[i].added += c.added
                        files[i].removed += c.removed
                    } else {
                        files.append(c)
                    }
                }
                out.append(.changes(ThreadChanges(files)))
            } else {
                out.append(contentsOf: run.map { .tool($0) })
            }
            run = []
        }
        for b in blocks {
            if case let .tool(t) = b, t.change != nil, !t.failed {
                run.append(t)
            } else {
                flush()
                out.append(b)
            }
        }
        flush()
        return out
    }
}

// MARK: Diff

extension DiffFile {
    /// Parses the review diff that fluxd sends, a `git diff` with a list of
    /// the changed files above it, into files. The lines above the first
    /// file and the headers of each file do not show.
    public static func parse(_ lines: [String]) -> [DiffFile] {
        var files: [DiffFile] = []
        var path: String?
        var added = 0
        var removed = 0
        var body: [DiffLine] = []
        var inHunk = false
        func flush() {
            // fluxd puts an empty line above each new file. It is not a line of the file before it.
            while let last = body.last, last.kind == .context, last.text.isBlank { body.removeLast() }
            if let path { files.append(DiffFile(path, added: added, removed: removed, lines: body)) }
            path = nil
            added = 0
            removed = 0
            body = []
            inHunk = false
        }
        for l in lines {
            if l.hasPrefix("diff --git ") {
                flush()
                let rest = String(l.dropFirst("diff --git ".count))
                path = l.after(" b/", or: rest.after("a/", or: rest)).trimmed
                continue
            }
            if path == nil { continue }
            if l.hasPrefix("@@") {
                inHunk = true
                body.append(DiffLine(l, .hunk))
            } else if !inHunk {
                // A new file of fluxd has no hunk. Its lines start with + at once.
                if l.hasPrefix("+") && !l.hasPrefix("+++") {
                    inHunk = true
                    added += 1
                    body.append(DiffLine(l, .added))
                } else if l == "Binary file" || l.hasPrefix("The new file is larger") {
                    body.append(DiffLine(l, .context))
                }
            } else if l.hasPrefix("+") {
                added += 1
                body.append(DiffLine(l, .added))
            } else if l.hasPrefix("-") {
                removed += 1
                body.append(DiffLine(l, .removed))
            } else {
                body.append(DiffLine(l, .context))
            }
        }
        flush()
        // fluxd adds an empty line at the end of each new file.
        return files.map { f in
            guard f.lines.last?.text == "+" else { return f }
            return DiffFile(f.path, added: f.added - 1, removed: f.removed, lines: Array(f.lines.dropLast()))
        }
    }
}
