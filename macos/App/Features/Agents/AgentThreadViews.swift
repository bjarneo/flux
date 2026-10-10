import FluxKit
import SwiftUI

// The parts of the agent thread: the agents window and the Inbox master use
// them. They follow the agent thread design of the Android app, see the
// "Agent screen" section of DESIGN.md, in the sizes of the Mac app. The
// agents window keeps its sidebar in the place of the strip of pills.

// MARK: Marks

/// A ring of 3 quarters that turns, for work that runs. With Reduce Motion,
/// the ring stands still.
struct RingSpinner: View {
    var size: CGFloat = 12
    var color: Color?
    var line: CGFloat = 2
    @Environment(\.tn) private var tn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { context in
            let turn = reduceMotion ? 0 : context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 0.9) / 0.9 * 360
            Circle()
                .trim(from: 0, to: 0.75)
                .stroke(color ?? tn.accent, style: StrokeStyle(lineWidth: line, lineCap: .butt))
                .rotationEffect(.degrees(45 + turn))
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// A status dot. With `pulse`, it fades to 30% and back in 1.6 s, for what
/// waits for the user. With Reduce Motion, it does not pulse.
struct PulseDot: View {
    let color: Color
    var size: CGFloat = 8
    var pulse = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(paused: !pulse || reduceMotion)) { context in
            let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
            let alpha = pulse && !reduceMotion ? 0.65 + 0.35 * cos(2 * .pi * t) : 1
            Circle().fill(color).opacity(alpha)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

/// The mark of an agent status: a ring that turns while it works, a dot
/// that pulses while it waits, else a dot.
struct StatusMark: View {
    let status: AgentStatus
    var dot: CGFloat = 8
    var ring: CGFloat = 11
    @Environment(\.tn) private var tn

    var body: some View {
        switch status {
        case .working: RingSpinner(size: ring, color: tn.accent)
        case .blocked: PulseDot(color: tn.red, size: dot)
        case .done: PulseDot(color: tn.green, size: dot, pulse: false)
        default: PulseDot(color: tn.dim, size: dot, pulse: false)
        }
    }
}

/// A bar with no end: 40% of the width slides from the left edge to the
/// right edge in 1.4 s. With Reduce Motion, it stands at the middle.
struct SlideBar: View {
    var color: Color
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geo in
            TimelineView(.animation(paused: reduceMotion)) { context in
                let w = geo.size.width * 0.4
                let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.4) / 1.4
                // An ease in and out, as the design moves the bar from -100% to 260% of its width.
                let e = t < 0.5 ? 2 * t * t : 1 - pow(-2 * t + 2, 2) / 2
                let x = reduceMotion ? (geo.size.width - w) / 2 : -w + e * w * 3.6
                Capsule().fill(color).frame(width: w).offset(x: x)
            }
        }
        .clipped()
        .accessibilityHidden(true)
    }
}

// MARK: Dialog

/// A numbered choice of a dialog. The `primary` choice has the accent fill,
/// and the others have the tonal fill. A tap sends its keys. The
/// description of a choice shows under its label.
struct AskChoiceButton: View {
    let choice: AgentChoice
    let primary: Bool
    let enabled: Bool
    var minHeight: CGFloat = TiledMetrics.rowHeight
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let ink = primary ? tn.onAccent : tn.text
        let shape = tileShape(12)
        Button(action: action) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text(choice.key)
                    .font(.system(size: 13, weight: .bold, design: .monospaced))
                    .foregroundStyle(ink.opacity(0.65))
                VStack(alignment: .leading, spacing: 2) {
                    Text(choice.label)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ink)
                        .multilineTextAlignment(.leading)
                    // The description of a choice of a question, under its label.
                    if !choice.detail.isEmpty {
                        Text(choice.detail)
                            .font(.system(size: 11.5))
                            .foregroundStyle(ink.opacity(0.72))
                            .multilineTextAlignment(.leading)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, minHeight: minHeight, alignment: .leading)
            .background(shape.fill(primary ? tn.accent : tn.line))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
        .help("Answer \(choice.key)")
        .accessibilityLabel(choice.detail.isEmpty ? "\(choice.key). \(choice.label)" : "\(choice.key). \(choice.label). \(choice.detail)")
        .accessibilityHint("Answer \(choice.key)")
    }
}

/// Lines of a command or a question in mono on the page color: the first
/// line in the body ink, the others in the second ink. The lines are never
/// cut, because they hold the command that a choice approves.
struct CodeLines: View {
    let lines: [String]
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(Array(lines.enumerated()), id: \.offset) { i, line in
                Text(line)
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(i == 0 ? tn.text : tn.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .textSelection(.enabled)
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tileShape(TiledMetrics.smallCorner).fill(tn.bg))
    }
}

/// The question of a blocked agent: the question line, then the lines above the choices.
struct AskText: View {
    let ask: AgentAsk
    var questionFont: Font = .system(size: 13)
    var spacing: CGFloat = 8
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: spacing) {
            if !ask.question.isEmpty {
                Text(ask.question)
                    .font(questionFont)
                    .foregroundStyle(tn.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !ask.lines.isEmpty { CodeLines(lines: ask.lines) }
        }
    }
}

// MARK: Thread

/// A token that looks like a file path or a file name, or code in backticks.
private let codeToken = try! NSRegularExpression(
    pattern: #"`[^`\n]+`|(?<![A-Za-z0-9_/.-])(?:[A-Za-z0-9_.-]+/)+[A-Za-z0-9_.-]*[A-Za-z0-9_]|(?<![A-Za-z0-9_/.-])[A-Za-z0-9_-]+(?:\.[A-Za-z0-9_-]+)*\.(?:sql|rb|ts|tsx|js|jsx|mjs|py|go|rs|kt|kts|swift|java|c|h|cpp|md|json|toml|yaml|yml|sh|css|scss|html|txt|lock|xml|qml)(?![A-Za-z0-9_])"#)

/// A message of the agent: body text, with paths and code in mono on a tile.
struct ThreadMessage: View {
    let text: String
    @Environment(\.tn) private var tn

    var body: some View {
        Text(styled)
            .font(.system(size: 13))
            .foregroundStyle(tn.text)
            .lineSpacing(4)
            .textSelection(.enabled)
            .padding(.horizontal, 2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var styled: AttributedString {
        var out = AttributedString()
        var at = text.startIndex
        let ns = NSRange(text.startIndex..., in: text)
        for m in codeToken.matches(in: text, range: ns) {
            guard let r = Range(m.range, in: text) else { continue }
            out += AttributedString(String(text[at..<r.lowerBound]))
            var code = String(text[r])
            if code.hasPrefix("`") && code.hasSuffix("`") && code.count >= 2 { code = String(code.dropFirst().dropLast()) }
            var chip = AttributedString("\u{2009}" + code + "\u{2009}")
            chip.font = .system(size: 12, design: .monospaced)
            chip.backgroundColor = tn.tile
            out += chip
            at = r.upperBound
        }
        out += AttributedString(String(text[at...]))
        return out
    }
}

/// A tool call: a mark, the name of the tool, and its arguments in 1 row,
/// and the result under it while `open`. A tap opens and closes the result.
/// A tool that `running` shows a turning ring.
struct ThreadToolView: View {
    let tool: ThreadTool
    let running: Bool
    let open: Bool
    let toggle: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape(12)
        let args = tool.args.isEmpty ? tool.result.first ?? "" : tool.args
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 10) {
                    if running {
                        RingSpinner(size: 13, color: tn.accent)
                    } else {
                        Image(systemName: tool.failed ? "xmark" : "checkmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(tool.failed ? tn.red : tn.green)
                    }
                    Text(tool.name)
                        .font(.system(size: 12, weight: .bold, design: .monospaced))
                        .foregroundStyle(tn.text)
                    Text(args)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    if !tool.result.isEmpty {
                        Image(systemName: open ? "chevron.up" : "chevron.down")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(tn.sub)
                    }
                }
                .frame(minHeight: 36)
                if open && !tool.result.isEmpty {
                    Text(tool.result.joined(separator: "\n"))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(tn.sub)
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.leading, 26)
                        .padding(.bottom, 12)
                }
            }
            .padding(.horizontal, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(tn.offTile))
            .overlay(shape.strokeBorder(tn.line))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(tool.result.isEmpty)
        .accessibilityLabel("\(tool.name) \(tool.args)")
        .accessibilityValue(running ? "Runs" : tool.failed ? "Failed" : "Done")
        .accessibilityHint(open ? "Hides the result" : "Shows the result")
    }
}

/// The summary of a run of file edits: the files with their counts. A tap
/// opens the changes when `review` is set.
struct ThreadChangesView: View {
    let changes: ThreadChanges
    let review: (() -> Void)?
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape(12)
        Button { review?() } label: {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Image(systemName: "plusminus").foregroundStyle(tn.magenta)
                    Text(changes.files.count == 1 ? "Changed 1 file" : "Changed \(changes.files.count) files")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(tn.text)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text("+\(changes.added)").font(.system(size: 12, design: .monospaced)).foregroundStyle(tn.green)
                    Text("−\(changes.removed)").font(.system(size: 12, design: .monospaced)).foregroundStyle(tn.red)
                }
                ForEach(changes.files, id: \.path) { f in
                    HStack(spacing: 8) {
                        Text(f.path)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(tn.sub)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Text("+\(f.added)").font(.system(size: 11, design: .monospaced)).foregroundStyle(tn.green)
                        if f.removed > 0 { Text("−\(f.removed)").font(.system(size: 11, design: .monospaced)).foregroundStyle(tn.red) }
                    }
                }
                if review != nil {
                    Text("Review changes").font(.system(size: 12, weight: .semibold)).foregroundStyle(tn.accent)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(tn.tile))
            .overlay(shape.strokeBorder(tn.line))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .disabled(review == nil)
        .accessibilityElement(children: .combine)
        .accessibilityHint(review == nil ? "" : "Opens the changes")
    }
}

/// A prompt or an answer of the user: a bubble at the trailing edge, and
/// `meta` under it when it is set.
struct ThreadYou: View {
    let text: String
    var meta: String?
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4, topTrailingRadius: 16, style: .continuous)
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(tn.text)
                .textSelection(.enabled)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(shape.fill(tn.accentTile))
                .overlay(shape.strokeBorder(tn.lineHi))
            if let meta {
                Text(meta).font(.system(size: 11, design: .monospaced)).foregroundStyle(tn.sub)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        .padding(.leading, 48)
    }
}

/// The line at the end of the thread of an agent that waits for the user.
struct ThreadWaiting: View {
    @Environment(\.tn) private var tn

    var body: some View {
        HStack(spacing: 8) {
            PulseDot(color: tn.red)
            Text("Waiting for you").font(.system(size: 12))
            Image(systemName: "arrow.down").font(.system(size: 12))
        }
        .foregroundStyle(tn.red)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

/// "Done", with the time of the last turn when it is known.
func doneText(_ worked: String) -> String { worked.isEmpty ? "Done" : "Done in \(worked)" }

/// The line at the end of the thread of an agent that finished.
struct ThreadDone: View {
    let worked: String
    @Environment(\.tn) private var tn

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle").font(.system(size: 12))
            Text(doneText(worked)).font(.system(size: 12))
        }
        .foregroundStyle(tn.green)
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }
}

/// Output lines that the thread does not know, as a small terminal.
struct ThreadRaw: View {
    let lines: [TermLine]
    @State private var width: CGFloat = 0
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape(12)
        VStack(alignment: .leading, spacing: 0) {
            if width > 0 { TermLinesView(lines: lines, width: width).textSelection(.enabled) }
        }
        .frame(maxWidth: .infinity, minHeight: termRowHeight, alignment: .leading)
        .padding(.vertical, 10)
        .background(GeometryReader { g in
            Color.clear
                .onAppear { width = g.size.width }
                .onChange(of: g.size.width) { _, w in width = w }
        })
        .background(shape.fill(tn.offTile))
        .overlay(shape.strokeBorder(tn.line))
    }
}

// MARK: Changes

/// The changes of the repository of an agent: each file with its counts
/// and its diff lines in color. `files` is nil while the diff loads.
/// `problem` tells why no diff shows. Escape closes the sheet.
struct ChangesSheet: View {
    let files: [DiffFile]?
    let problem: String?
    let truncated: Bool
    @Environment(\.tn) private var tn
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text("Changes")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tn.text)
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: 0)
                if let files, !files.isEmpty {
                    Text("+\(files.reduce(0) { $0 + $1.added })").foregroundStyle(tn.green)
                    Text("−\(files.reduce(0) { $0 + $1.removed })").foregroundStyle(tn.red)
                }
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .font(.system(size: 12, design: .monospaced))
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if let files {
                        if files.isEmpty {
                            Text(problem ?? "No changes in this repository.")
                                .font(.system(size: 13))
                                .foregroundStyle(tn.sub)
                        } else {
                            if truncated {
                                Text("The diff is longer than the preview limit. Older files are cut.")
                                    .font(.system(size: 12))
                                    .foregroundStyle(tn.sub)
                            }
                            ForEach(Array(files.enumerated()), id: \.offset) { _, f in DiffCard(file: f) }
                        }
                    } else {
                        LineSkeleton(widths: [0.7, 0.9, 0.5, 0.8], label: "Reading the changes")
                    }
                }
                .padding(.horizontal, 12)
                .padding(.bottom, 16)
            }
        }
        .frame(minWidth: 560, idealWidth: 720, minHeight: 420, idealHeight: 640)
        .background(tn.tile)
    }
}

/// A file of the changes: its path and counts, then its diff lines.
private struct DiffCard: View {
    let file: DiffFile
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape(12)
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(file.path).foregroundStyle(tn.text).frame(maxWidth: .infinity, alignment: .leading)
                Text("+\(file.added)").foregroundStyle(tn.green)
                if file.removed > 0 { Text("−\(file.removed)").foregroundStyle(tn.red) }
            }
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            Rectangle().fill(tn.line).frame(height: 1)
            Text(diffText)
                .font(.system(size: 11, design: .monospaced))
                .lineSpacing(3)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(shape.fill(tn.bg))
        .overlay(shape.strokeBorder(tn.line))
        .clipShape(shape)
    }

    private var diffText: AttributedString {
        var out = AttributedString()
        for (i, l) in file.lines.enumerated() {
            var part = AttributedString((i > 0 ? "\n" : "") + l.text)
            switch l.kind {
            case .hunk: part.foregroundColor = tn.cyan
            case .added: part.foregroundColor = tn.green
            case .removed: part.foregroundColor = tn.red
            case .context: part.foregroundColor = tn.sub
            }
            out += part
        }
        return out
    }
}
