import AppKit
import FluxKit
import SwiftUI

/// The content of an agents window: the herdr agents of a computer on the
/// left, and the thread of the selected agent on the right. The agents that
/// need input come first.
struct AgentsView: View {
    @Bindable var model: AgentsWindowModel

    var body: some View {
        let device = model.device
        let online = device?.online == true
        let name = device?.name ?? "the computer"
        Group {
            if !online {
                ContentUnavailableView("\(name) is offline", systemImage: "wifi.slash",
                                       description: Text("The agents show when \(name) is on the same network."))
            } else if let herdr = model.herdr {
                content(herdr, name: name)
            } else {
                ProgressView("Loading the agents of \(name)…")
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .task(id: online) {
            if online { model.plugin.request(model.deviceId) }
        }
    }

    @ViewBuilder
    private func content(_ herdr: HerdrState, name: String) -> some View {
        if !herdr.enabled {
            unavailable("Agent status is off",
                        "On \(name), set herdr = true in ~/.config/flux/config.toml. Then run systemctl --user reload fluxd.")
        } else if !herdr.running {
            unavailable("herdr is not running", "Start herdr on \(name). Its coding agents show here.")
        } else if herdr.agents.isEmpty {
            unavailable("No agents yet", "Start a coding agent in a herdr pane on \(name). It shows here.")
        } else {
            HSplitView {
                AgentList(model: model, agents: herdr.sorted)
                    .frame(minWidth: 220, idealWidth: 260, maxWidth: 360)
                Group {
                    if let pane = model.selection {
                        AgentDetail(model: model, pane: pane, name: name)
                            .id(pane)
                    } else {
                        ContentUnavailableView("Select an agent", systemImage: "brain",
                                               description: Text("Its thread shows here."))
                    }
                }
                .frame(minWidth: 400, maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func unavailable(_ title: String, _ text: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "brain")
        } description: {
            Text(text)
        } actions: {
            Button("Refresh") { model.plugin.request(model.deviceId) }
        }
    }
}

/// The agents of the computer, with a refresh button.
private struct AgentList: View {
    @Bindable var model: AgentsWindowModel
    let agents: [HerdrAgent]

    var body: some View {
        List(selection: $model.selection) {
            ForEach(agents) { AgentRow(agent: $0).tag($0.pane) }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Text(agents.count == 1 ? "1 agent" : "\(agents.count) agents")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button { model.plugin.request(model.deviceId) } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Refresh the agent list")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .onAppear {
            if model.selection == nil { model.selection = agents.first?.pane }
        }
    }
}

/// 1 agent in the list: its status, project, workspace, and title.
private struct AgentRow: View {
    let agent: HerdrAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                AgentStatusLabel(status: agent.status)
                Spacer()
                Text(agent.agent)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(agent.project.isEmpty ? agent.pane : agent.project)
                    .fontWeight(.semibold)
                    .lineLimit(1)
                if !agent.workspace.isEmpty && agent.workspace != agent.project {
                    Text(agent.workspace)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Text(agent.title.isEmpty ? agent.pane : agent.title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
        }
        .padding(.vertical, 4)
    }
}

/// How often the thread reads the output again while the agent works.
private let workingRefresh: Duration = .seconds(5)

/// An answer that this window sent, for the thread: `text` shows as a
/// bubble of the user with `meta` under it, after the block `after`. The
/// output of the agent does not show an answer to a dialog, so the window
/// keeps it while the agent works on it.
struct SentAnswer: Equatable {
    var text: String
    var meta: String
    var after: ThreadBlock?
    var working = false
    var at = Date()
}

/// 1 agent as a thread: its output as messages, tool calls, and changes,
/// with the newest at the bottom, and the dock under it. The dock shows
/// the question of a blocked agent with its choices, the step of a working
/// agent with Interrupt, or the end of a turn, and the composer. The view
/// reads the output again when the status changes, and every 5 seconds
/// while the agent works and the window shows.
private struct AgentDetail: View {
    let model: AgentsWindowModel
    let pane: String
    let name: String
    @Environment(\.tn) private var tn
    /// True while the changes show. The output then holds the diff.
    @State private var review = false
    @State private var keysOpen = false
    @State private var sent: SentAnswer?
    /// The last output of the agent, for the thread while the changes show.
    @State private var lastAnsi: HerdrOutput?

    private struct Refresh: Equatable {
        var online: Bool
        var status: AgentStatus?
        var visible: Bool
        var review: Bool
    }

    var body: some View {
        let agent = model.herdr?.agent(pane)
        let read = model.plugin.model.output(model.deviceId, pane: pane)
        // While the changes show, the output holds the diff, so the thread keeps the last output of the agent.
        let ansi = read.flatMap { $0.view != "diff" && !(review && $0.loading && $0.lines.isEmpty) ? $0 : nil }
        let out = ansi ?? lastAnsi
        let diff = read.flatMap { review && $0.view == "diff" ? $0 : nil }
        let texts = out?.lines.map(\.text)
        let thread = texts.map(AgentThread.parse)
        let ask = texts.flatMap { AgentAsk.find($0, maxLines: 6) }
        let control = agent != nil && model.herdr?.control == true
        let canReview = agent != nil && model.herdr?.review == true && model.device?.online == true
        VStack(spacing: 0) {
            if let agent {
                AgentHeader(agent: agent, loading: out?.loading == true && !(out?.lines.isEmpty ?? true), text: out?.text ?? "",
                            review: canReview ? { review = true } : nil, keysOpen: control ? $keysOpen : nil) {
                    model.plugin.read(model.deviceId, pane: pane)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                // The progress line: it moves while the agent works.
                ZStack {
                    Rectangle().fill(tn.line)
                    if agent.status == .working { SlideBar(color: tn.accent) }
                }
                .frame(height: 2)
                ThreadList(output: out, thread: thread, status: agent.status, sent: sent, review: canReview ? { review = true } : nil)
                if control {
                    ReplyControls(model: model, agent: agent, output: out, thread: thread, ask: ask, name: name,
                                  keysOpen: $keysOpen, review: canReview ? { review = true } : nil) { sent = $0 }
                } else {
                    Text("To answer from this Mac, set herdr_control = true on \(name).")
                        .font(.system(size: 12))
                        .foregroundStyle(tn.sub)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                        .background(DockShape().fill(tn.tile))
                }
            } else {
                ContentUnavailableView("The agent is gone", systemImage: "brain",
                                       description: Text("The agent in \(pane) on \(name) stopped or moved to another pane."))
            }
        }
        .background(tn.bg)
        .sheet(isPresented: $review) {
            ChangesSheet(files: diff.flatMap { !$0.loading || !$0.lines.isEmpty ? DiffFile.parse($0.lines.map(\.text)) : nil },
                         problem: diff?.error ?? diff?.lines.first?.text, truncated: diff?.truncated == true)
        }
        .onChange(of: ansi) { _, next in if let next { lastAnsi = next } }
        .onChange(of: agent?.status) { _, status in
            guard let s = sent else { return }
            if status == .working { sent?.working = true } else if s.working { sent = nil }
        }
        .task(id: Refresh(online: model.device?.online == true, status: agent?.status, visible: model.visible, review: review)) {
            guard model.visible, model.device?.online == true, agent != nil else { return }
            // A new status reads at once. Only the polls wait for the last read.
            model.plugin.read(model.deviceId, pane: pane, review: review)
            while agent?.status == .working {
                try? await Task.sleep(for: workingRefresh)
                if Task.isCancelled { return }
                model.plugin.poll(model.deviceId, pane: pane)
            }
        }
        .onDisappear { model.plugin.closeOutput(model.deviceId, pane: pane) }
    }
}

/// The header of an agent: its status, task, agent, and pane, then
/// Changes, Keys, Copy, and Refresh.
private struct AgentHeader: View {
    let agent: HerdrAgent
    let loading: Bool
    /// The output as plain text, for the copy button. A row of the output
    /// selects only its own text.
    let text: String
    let review: (() -> Void)?
    let keysOpen: Binding<Bool>?
    let refresh: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            StatusMark(status: agent.status)
            VStack(alignment: .leading, spacing: 2) {
                Text(agent.title.isEmpty ? (agent.project.isEmpty ? agent.pane : agent.project) : agent.title)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tn.text)
                    .lineLimit(1)
                Text("\(agent.agent) · \(agent.pane) · \(agent.status.label)")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(tn.sub)
                    .lineLimit(1)
            }
            .accessibilityElement(children: .combine)
            Spacer()
            if let review {
                Button(action: review) { Label("Changes", systemImage: "plusminus") }
                    .help("Show the changes of the repository")
                    .keyboardShortcut("d", modifiers: .command)
            }
            if let keysOpen {
                Toggle(isOn: keysOpen) { Label("Keys", systemImage: "keyboard") }
                    .toggleStyle(.button)
                    .help("Show the keys Esc, Tab, Up, Down, and Enter")
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            } label: { Image(systemName: "doc.on.doc") }
                .buttonStyle(.borderless)
                .disabled(text.isEmpty)
                .help("Copy the output")
            if loading {
                ProgressView().controlSize(.small)
            } else {
                Button(action: refresh) { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .help("Read the output again")
                    .keyboardShortcut("r", modifiers: .command)
            }
        }
        .controlSize(.small)
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
        Group {
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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
                        Text("Older lines are cut.").font(.system(size: 11, design: .monospaced)).foregroundStyle(tn.sub)
                    }
                    if let error = out.error {
                        Text(error).font(.system(size: 12)).foregroundStyle(tn.red)
                    }
                    if blocks.isEmpty && sent == nil {
                        Text("No output yet.").font(.system(size: 12, design: .monospaced)).foregroundStyle(tn.sub)
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
                .padding(.horizontal, 16)
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
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(tn.accent)
                            .frame(width: 32, height: 32)
                            .background(Circle().fill(tn.tileHi))
                            .overlay(Circle().strokeBorder(tn.line))
                    }
                    .buttonStyle(.plain)
                    .padding(12)
                    .help("Show the newest lines")
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
