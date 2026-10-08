import FluxKit
import SwiftUI

/// How often the agent screen reads the output again while the agent works.
private let workingRefresh: Duration = .seconds(5)

/// One herdr agent as a thread. A strip of pills under the top bar opens
/// the other agents of the computer in the place of this one.
struct AgentScreen: View {
    let deviceId: String
    @State private var pane: String

    init(deviceId: String, pane: String) {
        self.deviceId = deviceId
        _pane = State(initialValue: pane)
    }

    var body: some View {
        AgentThreadScreen(deviceId: deviceId, pane: pane) { pane = $0 }
            .id(pane)
    }
}

/// An answer that this screen sent, for the thread: `text` shows as a
/// bubble of the user with `meta` under it, after the block `after`. The
/// output of the agent does not show an answer to a dialog, so the screen
/// keeps it while the agent works on it.
struct SentAnswer: Equatable {
    var text: String
    var meta: String
    var after: ThreadBlock?
    var working = false
    var at = Date()
}

/// The output of one agent as a thread: messages, tool calls, and changes,
/// with the newest at the bottom, and the dock under it. The dock shows the
/// question of a blocked agent with its choices, the step of a working
/// agent with Interrupt, or the end of a turn, and the composer. The
/// screen reads the output on open, when the status changes, and every 5
/// seconds while the agent works.
private struct AgentThreadScreen: View {
    @Environment(AppModel.self) private var model
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.tn) private var tn
    let deviceId: String
    let pane: String
    let pick: (String) -> Void
    @State private var asking = false
    @State private var closeError: String?
    /// True while the changes show. The output then holds the diff.
    @State private var review = false
    @State private var keysOpen = false
    @State private var sent: SentAnswer?
    /// The last output of the agent, for the thread while the changes show.
    @State private var lastAnsi: HerdrOutput?

    private struct Refresh: Equatable {
        var online: Bool
        var active: Bool
        var status: AgentStatus?
        var review: Bool
    }

    var body: some View {
        let device = model.device(deviceId)
        let online = model.demo || device?.online == true
        let name = device?.name ?? "the computer"
        if let plugin = model.core.plugin(HerdrPlugin.self) {
            let herdr = model.demo ? DemoMode.herdr : plugin.model.states[deviceId]
            let agent = herdr?.agent(pane)
            let read = model.demo ? DemoMode.output(pane: pane, review: review) : plugin.model.output(deviceId, pane: pane)
            // While the changes show, the output holds the diff, so the thread keeps the last output of the agent.
            let ansi = read.flatMap { $0.view != "diff" && !(review && $0.loading && $0.lines.isEmpty) ? $0 : nil }
            let out = ansi ?? lastAnsi
            let diff = read.flatMap { review && $0.view == "diff" ? $0 : nil }
            let texts = out?.lines.map(\.text)
            let thread = texts.map(AgentThread.parse)
            let ask = texts.flatMap { AgentAsk.find($0, maxLines: 6) }
            let closing = plugin.model.actions[deviceId].map { $0.action == "close" && $0.pane == pane && $0.sending } ?? false
            let control = agent != nil && herdr?.control == true
            let canReview = agent != nil && herdr?.review == true && online
            VStack(spacing: 0) {
                if let agents = herdr?.sorted, agents.count >= 2, agent != nil {
                    AgentStrip(agents: agents, pane: pane, elapsed: thread?.elapsed ?? "", pick: pick)
                        .padding(.bottom, 8)
                }
                // The progress line: it moves while the agent works.
                ZStack {
                    Rectangle().fill(tn.line)
                    if agent?.status == .working && online { SlideBar(color: tn.accent) }
                }
                .frame(height: 2)
                if let closeError {
                    Text(closeError).font(.caption).foregroundStyle(tn.red).padding(.horizontal, 16).padding(.vertical, 6)
                }
                if !online {
                    PaneNotReachable(name: name, what: "The agent output").padding(16)
                    Spacer(minLength: 0)
                } else if agent == nil && herdr != nil {
                    ContentUnavailableView("The agent is gone", systemImage: "brain",
                                           description: Text("The agent in \(pane) on \(name) stopped or moved to another pane."))
                } else {
                    ThreadList(output: out, thread: thread, status: agent?.status, sent: sent,
                               review: canReview ? { review = true } : nil)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            if let agent {
                                VStack(spacing: 0) {
                                    FirstTaskNote(deviceId: deviceId, agent: agent)
                                    if control {
                                        AgentDock(deviceId: deviceId, agent: agent, output: out, thread: thread, ask: ask,
                                                  keysOpen: $keysOpen, review: canReview ? { review = true } : nil) { sent = $0 }
                                    } else {
                                        Text(.init("To answer from this iPhone, set `herdr_control = true` on \(name)."))
                                            .font(.caption)
                                            .foregroundStyle(tn.sub)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                            .padding(16)
                                            .background(DockShape().fill(tn.tile).ignoresSafeArea(edges: .bottom))
                                    }
                                }
                            }
                        }
                }
            }
            .background(tn.bg.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    VStack(spacing: 1) {
                        Text(agent.map { $0.title.isEmpty ? ($0.project.isEmpty ? pane : $0.project) : $0.title } ?? pane)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(tn.text)
                            .lineLimit(1)
                        Text([agent?.agent, pane, name].compactMap { $0 }.joined(separator: " · "))
                            .font(.caption2.monospaced())
                            .foregroundStyle(tn.sub)
                            .lineLimit(1)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityAddTraits(.isHeader)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Menu {
                        if online && agent != nil && !model.demo {
                            Button { plugin.read(deviceId, pane: pane) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                        }
                        if canReview {
                            Button { review = true } label: { Label("Changes", systemImage: "plusminus") }
                        }
                        if control {
                            Button { keysOpen.toggle() } label: { Label(keysOpen ? "Hide keys" : "Show keys", systemImage: "keyboard") }
                            Button(role: .destructive) { asking = true } label: { Label("Close the agent", systemImage: "xmark") }
                                .disabled(closing || model.demo)
                        }
                    } label: {
                        if out?.loading == true && !(out?.lines.isEmpty ?? true) {
                            ProgressView()
                        } else {
                            Image(systemName: "ellipsis.circle")
                        }
                    }
                    .accessibilityLabel("More actions")
                }
            }
            .sheet(isPresented: $review) {
                ChangesSheet(files: diff.flatMap { !$0.loading || !$0.lines.isEmpty ? DiffFile.parse($0.lines.map(\.text)) : nil },
                             problem: diff?.error ?? diff?.lines.first?.text, truncated: diff?.truncated == true)
            }
            .onChange(of: ansi) { _, next in if let next { lastAnsi = next } }
            .onChange(of: agent?.status) { _, status in
                guard let s = sent else { return }
                if status == .working { sent?.working = true } else if s.working { sent = nil }
            }
            .task(id: Refresh(online: online, active: scenePhase == .active, status: agent?.status, review: review)) {
                guard online, scenePhase == .active, agent != nil, !model.demo else { return }
                // A new status reads at once. Only the polls wait for the last read.
                plugin.read(deviceId, pane: pane, review: review)
                while agent?.status == .working {
                    try? await Task.sleep(for: workingRefresh)
                    if Task.isCancelled { return }
                    plugin.poll(deviceId, pane: pane)
                }
            }
            .onDisappear { plugin.closeOutput(deviceId, pane: pane) }
            .modifier(PaneCloser(deviceId: deviceId, pane: pane, title: "Close \(agent?.agent ?? "the agent")?",
                                 message: "herdr closes \(pane) on \(name), and the agent in it stops.",
                                 asking: $asking, error: $closeError))
        }
    }
}

/// The shape of the dock: round corners at the top.
struct DockShape: Shape {
    func path(in rect: CGRect) -> Path {
        UnevenRoundedRectangle(topLeadingRadius: 20, bottomLeadingRadius: 0, bottomTrailingRadius: 0, topTrailingRadius: 20, style: .continuous)
            .path(in: rect)
    }
}

/// How close to the end the thread must be, in points, to follow new blocks.
private let followSlack: CGFloat = 48

/// The thread of an agent: its blocks with the newest at the bottom, the
/// line that the agent waits for the user or finished, and the `sent`
/// answer. The view follows new blocks at the end. When the user scrolls up
/// to read older blocks, the view stays there, and a button goes back to
/// the newest blocks.
private struct ThreadList: View {
    let output: HerdrOutput?
    let thread: AgentThread?
    let status: AgentStatus?
    let sent: SentAnswer?
    let review: (() -> Void)?
    @Environment(\.tn) private var tn
    @State private var follow = true
    @State private var viewport: CGFloat = 0
    /// The tool calls that the user opened or closed. The key is the header and its number among the same headers.
    @State private var opened: [String: Bool] = [:]

    var body: some View {
        if let out = output, !(out.loading && out.lines.isEmpty) {
            if let error = out.error, out.lines.isEmpty {
                ContentUnavailableView("No output", systemImage: "exclamationmark.triangle", description: Text(error))
            } else {
                list(out)
            }
        } else {
            VStack {
                LineSkeleton(widths: [0.62, 0.9, 0.48, 0.84, 0.7, 0.36], label: "Reading the output")
                Spacer(minLength: 0)
            }
            .padding(16)
        }
    }

    private func list(_ out: HerdrOutput) -> some View {
        let blocks = thread?.blocks ?? []
        // The place of the sent answer: after its block, at the start without one, or at the end when the block left the output.
        let at: Int = {
            guard let sent else { return -2 }
            guard let after = sent.after else { return -1 }
            return blocks.lastIndex(of: after) ?? blocks.count - 1
        }()
        let rows = items(blocks)
        return ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if out.truncated {
                        Text("Older lines are cut.").font(.caption2.monospaced()).foregroundStyle(tn.sub)
                    }
                    if let error = out.error {
                        Text(error).font(.caption).foregroundStyle(tn.red)
                    }
                    if blocks.isEmpty && sent == nil {
                        Text("No output yet.").font(.caption.monospaced()).foregroundStyle(tn.sub)
                    }
                    if at == -1, let sent { ThreadYou(text: sent.text, meta: sent.meta) }
                    ForEach(rows, id: \.id) { row in
                        block(row, out: out, last: row.index == blocks.count - 1)
                        if row.index == at, let sent { ThreadYou(text: sent.text, meta: sent.meta) }
                    }
                    if status == .blocked { ThreadWaiting() }
                    if status == .done { ThreadDone(worked: thread?.worked ?? "") }
                    Color.clear
                        .frame(height: 1)
                        .id("end")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: ThreadEnd.self, value: g.frame(in: .named("thread")).minY)
                        })
                }
                .padding(.horizontal, 14)
                .padding(.top, 16)
                .padding(.bottom, 12)
            }
            .coordinateSpace(name: "thread")
            .defaultScrollAnchor(.bottom)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { viewport = g.size.height }
                    .onChange(of: g.size.height) { _, h in viewport = h }
            })
            .onPreferenceChange(ThreadEnd.self) { end in
                guard viewport > 0 else { return }
                follow = end <= viewport + followSlack
            }
            // New output scrolls to the newest blocks, unless the user reads older ones.
            .onChange(of: out.text) {
                if follow { proxy.scrollTo("end", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !follow && !out.lines.isEmpty {
                    Button {
                        follow = true
                        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(tn.accent)
                            .frame(width: 44, height: 44)
                            .background(Circle().fill(tn.tileHi))
                            .overlay(Circle().strokeBorder(tn.line))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .accessibilityLabel("Show the newest lines")
                }
            }
        }
    }

    /// A block with a key that stays the same while the output grows.
    private struct Row {
        let id: String
        let index: Int
        let block: ThreadBlock
    }

    private func items(_ blocks: [ThreadBlock]) -> [Row] {
        var seen: [String: Int] = [:]
        return blocks.enumerated().map { i, b in
            var head: String
            switch b {
            case .tool(let t): head = "tool:\(t.name)(\(t.args))"
            case .message(let m): head = "message:" + String(m.prefix(40))
            case .prompt(let p): head = "prompt:" + String(p.prefix(40))
            case .changes(let c): head = "changes:" + c.files.map(\.path).joined(separator: ",")
            case .raw(let from, _): head = "raw:\(from)"
            }
            let n = (seen[head] ?? 0) + 1
            seen[head] = n
            head += "#\(n)"
            return Row(id: head, index: i, block: b)
        }
    }

    @ViewBuilder
    private func block(_ row: Row, out: HerdrOutput, last: Bool) -> some View {
        switch row.block {
        case .message(let text): ThreadMessage(text: text)
        case .tool(let t):
            let running = status == .working && last
            let open = opened[row.id] ?? running
            ThreadToolView(tool: t, running: running, open: open) { opened[row.id] = !open }
        case .changes(let c): ThreadChangesView(changes: c, review: review)
        case .prompt(let text): ThreadYou(text: text)
        case .raw(let from, let to):
            ThreadRaw(lines: Array(out.lines[min(from, out.lines.count)..<min(to, out.lines.count)]))
        }
    }
}

private struct ThreadEnd: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// The state of the first task of a new agent, until it went.
private struct FirstTaskNote: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    let agent: HerdrAgent

    var body: some View {
        if let plugin = model.core.plugin(HerdrPlugin.self), let task = plugin.model.firstTasks[deviceId], task.pane == agent.pane {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                switch task.phase {
                case .starting, .waiting:
                    ProgressView().controlSize(.small)
                    Text("Flux sends your task when \(agent.agent) is ready.")
                case .answering:
                    Image(systemName: "questionmark.bubble").foregroundStyle(.orange)
                    Text("Answer \(agent.agent) first. Then Flux sends your task.")
                case .sending:
                    ProgressView().controlSize(.small)
                    Text("Sending your task…")
                case .sent:
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text("\(agent.agent) got your task.")
                case .failed(let reason):
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    Text("Your task did not go: \(reason) It is in the reply field.")
                }
                Spacer(minLength: 0)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            .task(id: task.phase) {
                guard task.phase == .sent else { return }
                try? await Task.sleep(for: .seconds(4))
                if !Task.isCancelled { plugin.clearFirstTask(deviceId) }
            }
        }
    }
}

/// A key of the key row of the dock: the label, the key name for herdr, and the name for VoiceOver.
private struct DockKey: Identifiable {
    let label: String
    let key: String
    let name: String
    var id: String { key }
}

private let dockKeys = [
    DockKey(label: "esc", key: "esc", name: "Escape"), DockKey(label: "tab", key: "tab", name: "Tab"),
    DockKey(label: "↑", key: "up", name: "Up"), DockKey(label: "↓", key: "down", name: "Down"),
    DockKey(label: "enter", key: "enter", name: "Enter"),
]

/// The dock of an agent under its thread. A blocked agent shows its
/// question and the choices, with Write for a text answer and Keys for the
/// key row. A working agent shows its step and Interrupt. A finished agent
/// shows the end of its turn. Under that, the composer takes a prompt as
/// text or as dictation. Each reply asks for Face ID or the passcode first,
/// see `ReplyLock`. `sentAnswer` gets each answer to a choice, for the thread.
private struct AgentDock: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    let deviceId: String
    let agent: HerdrAgent
    let output: HerdrOutput?
    let thread: AgentThread?
    let ask: AgentAsk?
    @Binding var keysOpen: Bool
    let review: (() -> Void)?
    let sentAnswer: (SentAnswer) -> Void
    @State private var text = ""
    @State private var lockError: String?
    @State private var voiceError: String?
    @State private var dictation = Dictation()
    /// True while the prompt shows in the large editor.
    @State private var expanded = false
    /// True while a blocked agent shows the composer in the place of its choices.
    @State private var writing = false
    /// The output that the last answer answered.
    @State private var answered: HerdrOutput?
    /// The number of the last prompt from the field.
    @State private var sentSeq = -1
    @FocusState private var focused: Bool

    private var plugin: HerdrPlugin? { model.core.plugin(HerdrPlugin.self) }

    var body: some View {
        let reply = plugin?.model.reply(deviceId, pane: agent.pane)
        let blocked = agent.status == .blocked
        let choices = blocked ? output?.choices ?? [] : []
        let asking = blocked && !choices.isEmpty && !writing
        let sendingPrompt = reply?.sending == true && reply?.action == "prompt"
        VStack(alignment: .leading, spacing: 10) {
            if blocked {
                askHeader(hasChoices: !choices.isEmpty)
                if asking {
                    if let ask { AskText(ask: ask, questionFont: .callout.weight(.semibold), spacing: 6).padding(.horizontal, 4) }
                    // The choices keep 6 pt between them, so that a tap does not hit the next choice.
                    let open = reply?.sending != true && (answered == nil || (output != answered && output?.loading == false))
                    VStack(spacing: 6) {
                        ForEach(Array(choices.enumerated()), id: \.element.id) { i, c in
                            AskChoiceButton(choice: c, primary: i == 0, enabled: open) { answer(c) }
                        }
                    }
                }
            } else if agent.status == .working {
                workingRow
            } else if agent.status == .done {
                doneRow
            }
            if keysOpen {
                HStack(spacing: 6) {
                    ForEach(dockKeys) { k in
                        Button { keys(k.key) } label: {
                            Text(k.label)
                                .font(.caption.monospaced().weight(.medium))
                                .foregroundStyle(tn.sub)
                                .frame(maxWidth: .infinity, minHeight: 44)
                                .background(tileShape(8).fill(tn.bg))
                                .overlay(tileShape(8).strokeBorder(tn.line))
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel(k.name)
                    }
                }
            }
            if !asking { composer(sending: sendingPrompt) }
            if dictation.phase != .idle {
                Text(dictation.pending.isEmpty && dictation.settled.isEmpty ? "Listening…" : dictation.settled + " " + dictation.pending)
                    .font(.caption)
                    .foregroundStyle(tn.sub)
                    .lineLimit(2)
            }
            if let problem = lockError ?? voiceError ?? dictation.error ?? reply?.error {
                Text(problem).font(.caption).foregroundStyle(tn.red).fixedSize(horizontal: false, vertical: true)
                // fluxd refused the prompt because the agent waits for a
                // choice. The user can type the same text into the dialog.
                if problem == reply?.error, let r = reply, r.blocked, let blocked = r.text {
                    Button("Send as answer") { answerText(blocked) }
                        .font(.caption.weight(.semibold))
                        .accessibilityHint("Types the text into the dialog of \(agent.agent)")
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 14)
        .padding(.bottom, 8)
        .background(DockShape().fill(tn.tile).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) {
            // The line along the top edge and the round corners.
            DockShape().stroke(tn.line, lineWidth: 1).frame(height: 40).mask(alignment: .top) { Rectangle().frame(height: 20) }
        }
        .sheet(isPresented: $expanded) {
            FieldEditor(title: "Write to \(agent.agent)", text: $text, actionLabel: "Send",
                        actionEnabled: !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, onAction: send)
        }
        // A prompt that the computer accepted leaves the field.
        .onChange(of: reply) { _, r in
            if let r, r.action == "prompt", !r.sending, r.error == nil, r.seq == sentSeq {
                text = ""
                writing = false
            }
        }
        // A first task that did not go waits in the field.
        .onChange(of: failedTask, initial: true) { _, failed in
            guard let failed, let plugin else { return }
            if text.isEmpty { text = failed }
            plugin.clearFirstTask(deviceId)
        }
        .onDisappear { dictation.cancel() }
    }

    /// The top row of the dock of a blocked agent: the agent asks, then
    /// Write and Keys. Write shows the composer in the place of the
    /// choices, and Choices shows the choices again.
    private func askHeader(hasChoices: Bool) -> some View {
        HStack(spacing: 8) {
            PulseDot(color: tn.red)
            Text("\(agent.agent) asks")
                .font(.caption.weight(.medium))
                .foregroundStyle(tn.red)
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            if hasChoices {
                Button { writing.toggle() } label: { Label(writing ? "Choices" : "Write", systemImage: "pencil") }
                    .accessibilityHint(writing ? "Shows the choices" : "Shows the text field in the place of the choices")
            }
            Button { keysOpen.toggle() } label: { Label("Keys", systemImage: "keyboard") }
                .accessibilityValue(keysOpen ? "Shown" : "Hidden")
        }
        .font(.footnote.weight(.semibold))
        .tint(tn.accent)
        .buttonStyle(.borderless)
        .padding(.horizontal, 4)
        .frame(minHeight: 32)
    }

    /// The dock row of a working agent: its step and time, and Interrupt, which sends Escape.
    private var workingRow: some View {
        HStack(spacing: 12) {
            RingSpinner(size: 18, color: tn.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text((thread?.step).flatMap { $0.isEmpty ? nil : $0 } ?? "Working")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(2)
                Text([thread?.elapsed ?? "", "\(agent.agent) is working"].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.caption2.monospaced())
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Button { keys("esc") } label: {
                HStack(spacing: 6) {
                    Text("Interrupt").font(.footnote.weight(.semibold)).foregroundStyle(tn.text)
                    Text("esc").font(.caption2.monospaced()).foregroundStyle(tn.sub).accessibilityHidden(true)
                }
                .padding(.horizontal, 12)
                .frame(minHeight: 44)
                .background(tileShape(10).fill(tn.line))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Interrupt \(agent.agent)")
        }
        .padding(.horizontal, 4)
    }

    /// The dock row of a finished agent: the end of its turn, and Review changes.
    private var doneRow: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.circle").foregroundStyle(tn.green)
            Text(doneText(thread?.worked ?? ""))
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(tn.text)
                .frame(maxWidth: .infinity, alignment: .leading)
            if let review {
                Button("Review changes", action: review)
                    .font(.footnote.weight(.semibold))
                    .tint(tn.accent)
                    .buttonStyle(.borderless)
            }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 32)
    }

    /// The composer: a round field on the page color, the mic key, and the send key.
    private func composer(sending: Bool) -> some View {
        let dictating = dictation.phase != .idle
        let canSend = !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !sending
        let placeholder = agent.status == .blocked ? "Tell \(agent.agent) what to do differently"
            : agent.status == .working ? "Steer \(agent.agent) while it works" : "Write to \(agent.agent)"
        return HStack(alignment: .bottom, spacing: 8) {
            HStack(alignment: .bottom, spacing: 0) {
                TextField(placeholder, text: $text, axis: .vertical)
                    .font(.subheadline)
                    .lineLimit(1...4)
                    .focused($focused)
                    .padding(.leading, 16)
                    .padding(.trailing, 4)
                    .padding(.vertical, 12)
                if !text.isEmpty {
                    HStack(spacing: 0) {
                        ClearKey(text: $text)
                        ExpandKey(isPresented: $expanded)
                    }
                    .padding(.trailing, 4)
                    .padding(.bottom, 2)
                }
            }
            .background(RoundedRectangle(cornerRadius: 22, style: .continuous).fill(tn.bg))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).strokeBorder(tn.lineHi))
            if Dictation.available {
                Button {
                    if dictating { dictation.stop() } else { dictate() }
                } label: {
                    Image(systemName: dictating ? "stop.fill" : "mic")
                        .font(.system(size: 18, weight: .medium))
                        .foregroundStyle(dictating ? tn.onAccent : tn.text)
                        .frame(width: 44, height: 44)
                        .background(Circle().fill(dictating ? tn.green : tn.line))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dictating ? "Stop the dictation" : "Dictate")
            }
            // The key keeps its color with no text, as in the design. It takes no tap then.
            Button(action: send) {
                Group {
                    if sending {
                        RingSpinner(size: 18, color: tn.onAccent)
                    } else {
                        Image(systemName: "arrow.up").font(.system(size: 18, weight: .semibold))
                    }
                }
                .foregroundStyle(tn.onAccent)
                .frame(width: 44, height: 44)
                .background(Circle().fill(tn.accent))
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("Send")
        }
    }

    /// The text of the first task of this agent when it failed.
    private var failedTask: String? {
        guard let task = plugin?.model.firstTasks[deviceId], task.pane == agent.pane, case .failed = task.phase else { return nil }
        return task.text
    }

    private func guarded(_ action: @escaping @MainActor () -> Void) {
        if model.demo {
            model.show(DemoMode.sendsNothing)
            return
        }
        lockError = nil
        ReplyLock.run(reason: "Answer agents on \(AgentsFeature.name(model, deviceId)).", action: action) { lockError = $0 }
    }

    private func keys(_ k: String...) {
        guarded { plugin?.sendKeys(deviceId, pane: agent.pane, k) }
    }

    /// Sends the digit of a choice, and keeps the answer for the thread.
    private func answer(_ c: AgentChoice) {
        let shown = output
        let last = thread?.blocks.last
        guarded {
            guard let plugin else { return }
            answered = shown
            sentAnswer(SentAnswer(text: c.label, meta: "Sent key \(c.key)", after: last))
            plugin.sendKeys(deviceId, pane: agent.pane, [c.key])
        }
    }

    private func send() {
        let t = text
        guard !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guarded {
            guard let plugin else { return }
            plugin.sendPrompt(deviceId, pane: agent.pane, t)
            sentSeq = plugin.model.reply(deviceId, pane: agent.pane)?.seq ?? -1
        }
    }

    /// Sends the text of a refused prompt again as the answer to the dialog of the agent.
    private func answerText(_ t: String) {
        guard plugin?.model.reply(deviceId, pane: agent.pane)?.sending != true else { return }
        guarded {
            guard let plugin else { return }
            plugin.sendPrompt(deviceId, pane: agent.pane, t, answer: true)
            sentSeq = plugin.model.reply(deviceId, pane: agent.pane)?.seq ?? -1
        }
    }

    /// Dictates on the iPhone. The words go into the field and wait for Send.
    private func dictate() {
        voiceError = nil
        lockError = nil
        if let problem = MicFeature.dictationProblem(model.core) {
            voiceError = problem
            return
        }
        Task { @MainActor in
            if let problem = await Dictation.authorize() {
                voiceError = problem
                return
            }
            let hints = [agent.agent, agent.project, agent.workspace].filter { !$0.isEmpty }
            // The dictation uses the languages of the iPhone.
            dictation.start(language: "", hints: hints) { spoken in
                let edit = DictationText.insert(text, start: text.utf16.count, end: text.utf16.count, spoken: spoken)
                text = edit.text
            }
        }
    }
}
