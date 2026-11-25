import AppKit
import FluxKit
import Observation
import SwiftUI

// The cards of the chats. The computer writes on the left: approvals,
// received files, the last clip, and the answers to approvals. This Mac
// writes on the right: links, texts, clips, and files. The list of chats
// shows the approvals and the pair requests as cards, and the menu bar
// panel also shows the agents as cards. They follow the Conversations
// design of the Android app, in the sizes of the Mac app.

// MARK: Answers

/// The answers that the menu bar panel sent to the agents, by computer and
/// pane. An answer shows on the card of the agent while the agent works on
/// it, for 10 minutes at most. The item of an agent changes when its
/// status changes, so the answers live here and not in the card.
@MainActor
@Observable
final class ChatAnswers {
    static let shared = ChatAnswers()

    private struct Entry {
        var text: String
        var working = false
        var at = Date()
    }

    private var entries: [String: Entry] = [:]

    /// Keeps the answer `text` to the agent in `pane`.
    func sent(_ text: String, _ deviceId: String, pane: String) {
        entries[deviceId + "|" + pane] = Entry(text: text)
    }

    /// The answer to show for the agent in `pane`, or nil.
    func answer(_ deviceId: String, pane: String) -> String? {
        guard let e = entries[deviceId + "|" + pane], e.working, Date().timeIntervalSince(e.at) < 600 else { return nil }
        return e.text
    }

    /// The agent in `pane` has a new status. The answer shows while the
    /// agent works, and goes when the agent stops working.
    func status(_ status: AgentStatus, _ deviceId: String, pane: String) {
        let key = deviceId + "|" + pane
        guard let e = entries[key] else { return }
        if status == .working {
            if !e.working { entries[key]?.working = true }
        } else if e.working {
            entries[key] = nil
        }
    }
}

// MARK: Card of a computer

/// The width of the column of the chat, for the cards that take a part of it.
private struct ChatColumnKey: EnvironmentKey {
    static let defaultValue: CGFloat = 360
}

extension EnvironmentValues {
    var chatColumn: CGFloat {
        get { self[ChatColumnKey.self] }
        set { self[ChatColumnKey.self] = newValue }
    }
}

/// The top row of a card: the state in its color, the source in mono, and the time.
struct CardHead {
    let state: String
    let color: Color
    var source = ""
    let time: String
}

/// The text action at the bottom of a card. Without `run`, it is a line in the accent, such as "Writing a reply below".
struct CardAction {
    let label: String
    var help = ""
    var run: (() -> Void)?
}

/// The shape of a card from a computer: round, with a small corner at the bottom left.
private let inShape = UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 4, bottomTrailingRadius: 14,
                                             topTrailingRadius: 14, style: .continuous)

/// The shape of a card in the list of chats: the tile corner on each side.
private let listShape = UnevenRoundedRectangle(topLeadingRadius: TiledMetrics.tileCorner, bottomLeadingRadius: TiledMetrics.tileCorner,
                                               bottomTrailingRadius: TiledMetrics.tileCorner, topTrailingRadius: TiledMetrics.tileCorner,
                                               style: .continuous)

/// A card from a computer, on the left at 88% of the column: the `mark`
/// and the top row, the title, the `detail` in mono, a bar, `extra`, and the
/// text action. A card that needs the user (`ask`) takes the full column
/// and a red border of 2 pt. In the list of chats (`list`), the card takes
/// the full width and the tile corners.
struct InCard<Mark: View, Extra: View>: View {
    let head: CardHead
    let title: String
    var mono = false
    var titleLines: Int?
    var detail = ""
    var progress: Double?
    var action: CardAction?
    var ask = false
    var list = false
    let mark: Mark
    let extra: Extra
    @Environment(\.tn) private var tn
    @Environment(\.chatColumn) private var column

    init(head: CardHead, title: String, mono: Bool = false, titleLines: Int? = nil, detail: String = "",
         progress: Double? = nil, action: CardAction? = nil, ask: Bool = false, list: Bool = false,
         @ViewBuilder mark: () -> Mark, @ViewBuilder extra: () -> Extra) {
        self.head = head
        self.title = title
        self.mono = mono
        self.titleLines = titleLines
        self.detail = detail
        self.progress = progress
        self.action = action
        self.ask = ask
        self.list = list
        self.mark = mark()
        self.extra = extra()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                mark
                Text(head.state)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(head.color)
                    .lineLimit(1)
                    .fixedSize()
                if !head.source.isEmpty {
                    Text("· " + head.source)
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(tn.sub)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 6)
                Text(head.time)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
                    .fixedSize()
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel([head.state, head.source, head.time].filter { !$0.isEmpty }.joined(separator: ", "))
            Text(title)
                .font(.system(size: 14, weight: .semibold, design: mono ? .monospaced : .default))
                .foregroundStyle(tn.text)
                .lineLimit(titleLines)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            if !detail.isEmpty {
                Text(detail)
                    .font(.system(size: 12, design: .monospaced))
                    .lineSpacing(2)
                    .foregroundStyle(tn.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let progress {
                ZStack(alignment: .leading) {
                    Capsule().fill(tn.line)
                    LineFill(fraction: progress, color: tn.accent).clipShape(Capsule())
                }
                .frame(height: 3)
                .padding(.top, 2)
            }
            extra
            if let action {
                if let run = action.run {
                    Button(action: run) {
                        Text(action.label)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tn.accent)
                            .frame(minHeight: 24)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(action.help.isEmpty ? action.label : action.help)
                } else {
                    Text(action.label)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tn.accent)
                        .frame(minHeight: 24)
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: list ? nil : max(0, ask ? column : column * 0.88), alignment: .leading)
        .frame(maxWidth: list ? .infinity : nil, alignment: .leading)
        .background((list ? listShape : inShape).fill(tn.tile))
        .overlay((list ? listShape : inShape).strokeBorder(ask ? tn.red : tn.line, lineWidth: ask ? 2 : 1))
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .contain)
    }
}

extension InCard where Extra == EmptyView {
    init(head: CardHead, title: String, mono: Bool = false, titleLines: Int? = nil, detail: String = "",
         progress: Double? = nil, action: CardAction? = nil, ask: Bool = false, list: Bool = false, @ViewBuilder mark: () -> Mark) {
        self.init(head: head, title: title, mono: mono, titleLines: titleLines, detail: detail, progress: progress,
                  action: action, ask: ask, list: list, mark: mark) { EmptyView() }
    }
}

/// A button of a card, 40 pt high: `primary` has the accent fill, the other the tonal fill.
struct CardButtonStyle: ButtonStyle {
    let primary: Bool

    func makeBody(configuration: Configuration) -> some View {
        CardButtonBody(configuration: configuration, primary: primary)
    }
}

/// The body of `CardButtonStyle`. A view reads the theme from the environment.
private struct CardButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let primary: Bool
    @Environment(\.tn) private var tn
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
        configuration.label
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(primary ? tn.onAccent : tn.text)
            .frame(maxWidth: .infinity, minHeight: 40)
            .background(shape.fill(primary ? tn.accent : tn.line))
            .contentShape(shape)
            .opacity(configuration.isPressed ? 0.8 : enabled ? 1 : TiledMetrics.disabledAlpha)
    }
}

// MARK: Inbox items

/// An agent, an approval, or a pair request at the time `at`, in the menu bar panel.
struct EventCard: View {
    let item: InboxItem
    let at: Date

    var body: some View {
        switch item.content {
        case .agent(let deviceId, let agent, let control):
            PanelAgentCard(item: item, deviceId: deviceId, agent: agent, control: control, at: at)
        case .approval(let request):
            ApprovalCard(item: item, request: request, at: at)
        case .pair(let deviceId):
            PairCard(item: item, deviceId: deviceId, at: at)
        }
    }
}

/// The key of a read of the output: the item, and whether its window is the key window.
private struct PromptRead: Equatable {
    let item: String
    let front: Bool
}

/// An agent in the menu bar panel: what it waits for, what it works on,
/// or that it is done. The rules of an agent that waits:
/// - The card reads the output when it shows and when its window comes to
///   the front. Only an output that comes after that read is fresh, and
///   only a fresh output gives choices.
/// - The question keeps the lines nearest the choices, and it is never cut.
/// - Each answer asks for Touch ID or the password first, see `ReplyLock`.
/// - After an answer, the choices stay off until a new output comes.
/// - A choice that rejects the action opens the chat of the agent in the
///   window, where the dock takes the text.
struct PanelAgentCard: View {
    let item: InboxItem
    let deviceId: String
    let agent: HerdrAgent
    let control: Bool
    let at: Date
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.controlActiveState) private var activeState
    @Environment(\.openWindow) private var openWindow
    /// True after this card asked for the output.
    @State private var didRead = false
    /// The output that the user answered.
    @State private var answered: HerdrOutput?
    @State private var lockError: String?

    /// True while the link to the computer is open.
    private var reachable: Bool { model.paired.first { $0.id == deviceId }?.online == true }

    var body: some View {
        let since = agent.status == .working ? model.core.plugin(HerdrPlugin.self)?.model.agentSince(device: deviceId, pane: agent.pane) : nil
        Group {
            if let since {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    card(elapsed: AgentTime.when(.working, since: since, now: context.date))
                }
            } else {
                card(elapsed: nil)
            }
        }
        // A computer that is not reachable dims its card, as `ComputerChatRow` does, and the choices take no tap.
        .opacity(reachable ? 1 : TiledMetrics.disabledAlpha)
        .task(id: PromptRead(item: item.key, front: activeState == .key)) {
            // Only an agent that waits or works reads its output, as on Android. A read of an idle pane makes herdr scroll it.
            guard agent.status == .blocked || agent.status == .working, let plugin = model.core.plugin(HerdrPlugin.self) else { return }
            // The first show reads. Later, only a window that comes to the front reads again.
            if didRead && activeState != .key { return }
            plugin.readPrompt(deviceId, pane: agent.pane)
            didRead = true
        }
        .onChange(of: agent.status, initial: true) { _, status in
            ChatAnswers.shared.status(status, deviceId, pane: agent.pane)
        }
    }

    /// The card. `elapsed` is the time of the status from the clock of this
    /// Mac, or nil to take the time that the output shows.
    @ViewBuilder
    private func card(elapsed: String?) -> some View {
        let plugin = model.core.plugin(HerdrPlugin.self)
        let blocked = agent.status == .blocked
        let out = plugin?.model.prompt(deviceId, pane: agent.pane)
        let fresh = Self.fresh(out, didRead: didRead)
        let choices = blocked ? fresh?.choices ?? [] : []
        let texts = fresh?.lines.map(\.text)
        let ask = blocked ? texts.flatMap { AgentAsk.find($0, maxLines: 4) } : nil
        let thread = blocked ? nil : texts.map(AgentThread.parse)
        let reply = plugin?.model.reply(deviceId, pane: agent.pane)
        let sending = reply?.sending == true
        let many = model.paired.count > 1
        let source = (item.sourceParts + (many ? [item.computer] : [])).joined(separator: " · ")
        InCard(head: CardHead(state: item.stateWord, color: tn.tone(item.tone), source: source, time: clockTime(at)),
               title: item.title,
               detail: detail(thread: thread, elapsed: elapsed),
               action: action(choices: !choices.isEmpty),
               ask: blocked) {
            StatusMark(status: agent.status, dot: 8, ring: 11)
        } extra: {
            if blocked {
                VStack(alignment: .leading, spacing: 6) {
                    if let error = out?.error {
                        Text(error)
                            .font(.system(size: 12))
                            .foregroundStyle(tn.red)
                            .fixedSize(horizontal: false, vertical: true)
                    } else if let ask {
                        // No line limit: the command that a choice approves shows in full.
                        if !ask.command && !ask.question.isEmpty {
                            Text(ask.question)
                                .font(.system(size: 13))
                                .foregroundStyle(tn.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if !ask.lines.isEmpty { promptLines(ask.lines) }
                    } else if let texts {
                        let prompt = Inbox.agentPrompt(texts, maxLines: 4)
                        if !prompt.isEmpty { promptLines(prompt.components(separatedBy: "\n")) }
                    } else {
                        LineSkeleton(widths: [0.8, 0.55], label: "Reading the question")
                    }
                    if let fresh, !choices.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(choices.enumerated()), id: \.element.id) { i, choice in
                                AskChoiceButton(choice: choice, primary: i == 0, enabled: control && reachable && !sending && fresh != answered,
                                                minHeight: 40) {
                                    answer(choice, fresh)
                                }
                            }
                        }
                        .padding(.top, 6)
                    }
                    if let problem = lockError ?? reply?.error {
                        Text(problem)
                            .font(.system(size: 12))
                            .foregroundStyle(tn.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if !control {
                        Text("Agent control is off on \(item.computer). To answer from this Mac, turn on Agent control in Flux on the computer, on the Access card.")
                            .font(.system(size: 12))
                            .foregroundStyle(tn.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if sending {
                        HStack(spacing: 8) {
                            RingSpinner(size: 14)
                            Text("Sending")
                                .font(.system(size: 12))
                                .foregroundStyle(tn.sub)
                        }
                    }
                }
            }
        }
    }

    /// The command or the question in mono, in the second ink. The lines are never cut.
    private func promptLines(_ lines: [String]) -> some View {
        Text(lines.joined(separator: "\n"))
            .font(.system(size: 12, design: .monospaced))
            .lineSpacing(2)
            .foregroundStyle(tn.sub)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    /// The line under the title: the answer, the step, and the time of a
    /// working agent. A done agent reads no output, so it shows that it
    /// waits for the next prompt.
    private func detail(thread: AgentThread?, elapsed: String?) -> String {
        switch agent.status {
        case .blocked:
            return ""
        case .working:
            let answer = ChatAnswers.shared.answer(deviceId, pane: agent.pane).map { "You answered: \($0)" } ?? ""
            let parts = [answer, thread?.step ?? "", elapsed ?? thread?.elapsed ?? ""].filter { !$0.isEmpty }
            return parts.isEmpty ? "Working" : parts.joined(separator: " · ")
        default:
            let worked = thread?.worked ?? ""
            return worked.isEmpty ? "Waits for the next prompt" : "Done in \(worked)"
        }
    }

    /// Open chat, which opens the chat of the agent in the window. The choices take its place.
    private func action(choices: Bool) -> CardAction? {
        if choices { return nil }
        return CardAction(label: "Open chat", help: "Open the chat of the agent in the Flux window") { openChat() }
    }

    /// Opens the chat of the agent in the window and brings Flux to the front.
    private func openChat() {
        model.open(.agent(deviceId, pane: agent.pane))
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }

    /// The output when it came after the read of this card, else nil.
    private static func fresh(_ out: HerdrOutput?, didRead: Bool) -> HerdrOutput? {
        guard didRead, let out, !out.loading, out.error == nil else { return nil }
        return out
    }

    /// Sends the keys of the choice after Touch ID or the password. The
    /// question on screen must still be the question that the user read. A
    /// choice that rejects the action opens the chat of the agent, where the
    /// user selects it and writes what the agent must do.
    private func answer(_ choice: AgentChoice, _ out: HerdrOutput) {
        guard answered != out else { return }
        if Chat.isTellChoice(choice) {
            openChat()
            return
        }
        lockError = nil
        let deviceId = deviceId
        let pane = agent.pane
        let model = model
        ReplyLock.run(reason: "answer agents on \(item.computer)", action: {
            guard let plugin = model.core.plugin(HerdrPlugin.self), answered != out else { return }
            guard plugin.model.prompt(deviceId, pane: pane)?.lines == out.lines else {
                lockError = "The question changed. Read it, then answer again."
                return
            }
            answered = out
            ChatAnswers.shared.sent(choice.label, deviceId, pane: pane)
            plugin.sendKeys(deviceId, pane: pane, choice.keys)
        }, onError: { lockError = $0 })
    }
}

/// A request that waits for Touch ID, with Deny and Approve. Approve opens
/// the approval prompt, which asks for Touch ID. The card never approves
/// by itself. In the list of chats (`list`), the source also names the
/// computer.
struct ApprovalCard: View {
    let item: InboxItem
    let request: ApproveRequest
    let at: Date
    var list = false
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let source = contextLine([request.service, list ? request.computerName : ""])
        InCard(head: CardHead(state: item.stateWord, color: tn.red, source: source, time: clockTime(at)),
               title: item.title, detail: approvalLine(request), ask: true, list: list) {
            PulseDot(color: tn.red, size: 8)
        } extra: {
            GeometryReader { geo in
                let inner = max(0, geo.size.width - 8)
                HStack(spacing: 8) {
                    Button("Deny") {
                        // Deny acts on the open request, so it must be the request of this card.
                        guard let plugin = model.core.plugin(ApprovePlugin.self), plugin.model.current?.id == request.id else { return }
                        plugin.deny()
                    }
                        .buttonStyle(CardButtonStyle(primary: false))
                        .frame(width: inner / 2.6)
                        .help("Deny the request")
                    Button(action: review) {
                        Label("Approve", systemImage: ApproveTexts.current.symbol)
                    }
                    .buttonStyle(CardButtonStyle(primary: true))
                    .frame(width: inner * 1.6 / 2.6)
                    .help("Open the approval prompt. It asks for Touch ID before it approves.")
                }
            }
            .frame(height: 40)
            .padding(.top, 6)
        }
    }

    private func review() {
        guard let plugin = model.core.plugin(ApprovePlugin.self) else { return }
        ApprovePromptWindow.show(plugin)
    }
}

/// The user and the terminal of a request, such as "user dev · pts/3".
func approvalLine(_ r: ApproveRequest) -> String {
    [r.user.isEmpty ? "" : "user \(r.user)", r.tty].filter { !$0.isEmpty }.joined(separator: " · ")
}

/// A computer that asks to pair. Compare the key opens the pairing page
/// with the full key. The card never pairs by itself. `list` is true in
/// the list of chats.
struct PairCard: View {
    let item: InboxItem
    let deviceId: String
    let at: Date
    var list = false
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        InCard(head: CardHead(state: item.stateWord, color: tn.red, time: clockTime(at)),
               title: item.title, detail: "Compare the key on both screens.", ask: true, list: list) {
            PulseDot(color: tn.red, size: 8)
        } extra: {
            Button("Compare the key", action: compare)
                .buttonStyle(CardButtonStyle(primary: true))
                .padding(.top, 6)
        }
    }

    private func compare() {
        model.destination = .computers
        model.computersPath = [.pairing(deviceId)]
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: Log

/// A file from the computer: its progress while it comes in, then Open.
struct ReceivedFileCard: View {
    let transfer: FileTransfer
    let computer: String
    var clearFinished: (() -> Void)?
    @Environment(\.tn) private var tn

    var body: some View {
        let t = transfer
        let folder = t.file?.deletingLastPathComponent().lastPathComponent ?? "Downloads"
        let state: (String, Color, String) = {
            switch t.state {
            case .running:
                let pct = t.fraction.map { "\(Int($0 * 100))% of \(byteText(t.size))" } ?? "\(byteText(t.bytes)) so far"
                return ("Receiving", tn.accent, pct)
            case .done: return ("Received", tn.green, "In \(folder)")
            case .failed: return ("Not received", tn.red, "Send it again from \(computer)")
            }
        }()
        InCard(head: CardHead(state: state.0, color: state.1, source: computer, time: clockTime(t.started)),
               title: t.name, mono: true, detail: state.2,
               progress: t.state == .running ? t.fraction : nil,
               action: open) {
            if t.state == .running {
                RingSpinner(size: 11, color: tn.accent)
            } else {
                PulseDot(color: state.1, size: 8, pulse: false)
            }
        }
        .contextMenu {
            if let file = t.file, t.state == .done {
                Button("Open") { NSWorkspace.shared.open(file) }
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            if let clearFinished {
                Divider()
                Button("Clear Finished Transfers", action: clearFinished)
            }
        }
    }

    private var open: CardAction? {
        guard transfer.state == .done, let file = transfer.file else { return nil }
        return CardAction(label: "Open", help: "Open \(transfer.name)") { NSWorkspace.shared.open(file) }
    }
}

/// The last clip that a computer sent. It is on the pasteboard of this Mac already.
struct ReceivedClipCard: View {
    let clip: ClipEvent
    @Environment(\.tn) private var tn

    var body: some View {
        let text = clip.image ? "An image" : clip.secret ? ClipEvent.hiddenText : clip.preview
        InCard(head: CardHead(state: "Clipboard", color: tn.cyan, source: clip.computer, time: clockTime(clip.at)),
               title: text, mono: !clip.image && !clip.secret, titleLines: 4) {
            PulseDot(color: tn.cyan, size: 8, pulse: false)
        }
    }
}

/// The answer of this Mac to a request: Approved or Denied.
struct AnswerCard: View {
    let record: ApproveRecord
    @Environment(\.tn) private var tn

    var body: some View {
        let ok = record.outcome == .approved || record.outcome == .enrolled
        let color = ok ? tn.green : tn.sub
        InCard(head: CardHead(state: record.outcome == .enrolled ? "Enrolled" : ok ? "Approved" : "Denied", color: color, source: record.request?.service ?? "",
                              time: clockTime(record.resolved ?? record.received)),
               title: title, detail: record.request.map(approvalLine) ?? "") {
            PulseDot(color: color, size: 8, pulse: false)
        }
    }

    /// "Approved sudo for dev", or the enrollment form.
    private var title: String {
        guard let r = record.request else { return record.summary }
        let noun = FluxPlatform.current.deviceNoun
        switch record.outcome {
        case .enrolled: return "Enrolled \(noun) on \(r.host)"
        case .denied where r.kind == .enroll: return "Denied the enrollment on \(r.host)"
        case .denied: return "Denied \(r.service)" + (r.user.isEmpty ? "" : " for \(r.user)")
        default: return "Approved \(r.service)" + (r.user.isEmpty ? "" : " for \(r.user)")
        }
    }
}

/// The shape of a text that this Mac sent: round, with a small corner at the bottom right.
private let outShape = UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 16, bottomTrailingRadius: 4,
                                              topTrailingRadius: 16, style: .continuous)

/// The shape of a file that this Mac sent.
private let outFileShape = UnevenRoundedRectangle(topLeadingRadius: 14, bottomLeadingRadius: 14, bottomTrailingRadius: 4,
                                                  topTrailingRadius: 14, style: .continuous)

/// A link, a text, or a clip that went out: a bubble at the right in mono,
/// at most 82% of the column, with `meta` under it.
struct SentBubble: View {
    let text: String
    let meta: String
    @Environment(\.tn) private var tn
    @Environment(\.chatColumn) private var column

    var body: some View {
        VStack(alignment: .trailing, spacing: 4) {
            Text(text)
                .font(.system(size: 12.5, design: .monospaced))
                .lineSpacing(3)
                .foregroundStyle(tn.text)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .background(outShape.fill(tn.accentTile))
                .overlay(outShape.strokeBorder(tn.lineHi, lineWidth: 1))
            Text(meta)
                .font(.system(size: 11))
                .foregroundStyle(tn.sub)
        }
        .frame(maxWidth: max(0, column * 0.82), alignment: .trailing)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A file or an image clip that went out: a card of 236 pt at the right
/// with its symbol, its name, and `meta`, and a bar while it runs.
struct SentFileCard: View {
    let icon: String
    let name: String
    let meta: String
    let state: FileTransfer.State
    var fraction: Double?
    var file: URL?
    var clearFinished: (() -> Void)?
    @Environment(\.tn) private var tn

    var body: some View {
        let failed: Bool = {
            if case .failed = state { return true }
            return false
        }()
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 18))
                    .foregroundStyle(tn.accent)
                    .frame(width: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                        .font(.system(size: 13, weight: .medium, design: .monospaced))
                        .foregroundStyle(tn.text)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(meta)
                        .font(.system(size: 12))
                        .foregroundStyle(failed ? tn.red : tn.sub)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                switch state {
                case .running:
                    RingSpinner(size: 14)
                case .done:
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(tn.green)
                case .failed:
                    Image(systemName: "xmark").font(.system(size: 13, weight: .semibold)).foregroundStyle(tn.red)
                }
            }
            if state == .running, let fraction {
                ZStack(alignment: .leading) {
                    Capsule().fill(tn.line)
                    LineFill(fraction: fraction, color: tn.accent).clipShape(Capsule())
                }
                .frame(height: 3)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 236)
        .background(outFileShape.fill(tn.accentTile))
        .overlay(outFileShape.strokeBorder(tn.lineHi, lineWidth: 1))
        .contentShape(outFileShape)
        .contextMenu {
            if let file, state == .done {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file]) }
            }
            if let clearFinished {
                Divider()
                Button("Clear Finished Transfers", action: clearFinished)
            }
        }
        .help(name)
        .frame(maxWidth: .infinity, alignment: .trailing)
    }
}

/// A size in bytes, such as "3.2 MB".
func byteText(_ n: Int64) -> String {
    ByteCountFormatter.string(fromByteCount: n, countStyle: .file)
}
