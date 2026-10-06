import AppKit
import FluxKit
import SwiftUI

/// The content of an agents window: the herdr agents of a computer on the
/// left, and the output of the selected agent on the right. The agents that
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
                                               description: Text("Its recent output shows here."))
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

/// How often the output view reads the output again while the agent works.
private let workingRefresh: Duration = .seconds(5)

/// The recent output of 1 agent in terminal colors, with the newest lines
/// at the bottom, and the reply controls. The view reads the output again
/// when the status changes, and every 5 seconds while the agent works and
/// the window shows.
private struct AgentDetail: View {
    let model: AgentsWindowModel
    let pane: String
    let name: String
    @State private var review = false
    @State private var reviewPath = ""
    @State private var appliedReviewPath = ""

    private struct Refresh: Equatable {
        var online: Bool
        var status: AgentStatus?
        var visible: Bool
    }

    var body: some View {
        let agent = model.herdr?.agent(pane)
        let out = model.plugin.model.output(model.deviceId, pane: pane)
        VStack(alignment: .leading, spacing: 12) {
            if let agent {
                AgentHeader(agent: agent, loading: out?.loading == true && !(out?.lines.isEmpty ?? true),
                            text: out?.text ?? "") {
                    model.plugin.read(model.deviceId, pane: pane)
                }
                if model.herdr?.review == true {
                    Picker("Agent view", selection: $review) {
                        Text("Output").tag(false)
                        Text("Changes").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: review) {
                        if review { appliedReviewPath = reviewPath }
                        model.plugin.read(model.deviceId, pane: pane, review: review, path: appliedReviewPath)
                    }
                    if review {
                        TextField("File path, or leave empty for all changes", text: $reviewPath)
                            .onSubmit { appliedReviewPath = reviewPath; model.plugin.read(model.deviceId, pane: pane, review: true, path: appliedReviewPath) }
                        Text("Replies include the selected review path.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                AgentOutput(output: out)
                if model.herdr?.control == true {
                    ReplyControls(model: model, agent: agent, output: review ? nil : out, name: name,
                                  reviewReady: !review || (out?.loading == false && out?.error == nil))
                } else {
                    Text("To answer from this Mac, set herdr_control = true on \(name).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            } else {
                ContentUnavailableView("The agent is gone", systemImage: "brain",
                                       description: Text("The agent in \(pane) on \(name) stopped or moved to another pane."))
            }
        }
        .padding(16)
        .task(id: Refresh(online: model.device?.online == true, status: agent?.status, visible: model.visible)) {
            guard model.visible, model.device?.online == true, agent != nil else { return }
            // A new status reads at once. Only the polls wait for the last read.
            model.plugin.read(model.deviceId, pane: pane, review: review, path: appliedReviewPath)
            while agent?.status == .working {
                try? await Task.sleep(for: workingRefresh)
                if Task.isCancelled { return }
                model.plugin.poll(model.deviceId, pane: pane)
            }
        }
        .onDisappear { model.plugin.closeOutput(model.deviceId, pane: pane) }
    }
}

private struct AgentHeader: View {
    let agent: HerdrAgent
    let loading: Bool
    /// The output as plain text, for the copy button. A row of the output
    /// selects only its own text.
    let text: String
    let refresh: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    AgentStatusLabel(status: agent.status)
                    Text("\(agent.agent) · \(agent.project.isEmpty ? agent.pane : agent.project)")
                        .font(.headline)
                        .lineLimit(1)
                }
                if !agent.title.isEmpty {
                    Text(agent.title)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer()
            Text(agent.pane)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
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
    }
}

/// The output of the agent as a small terminal: mono, and in the colors of
/// the agent.
private struct AgentOutput: View {
    let output: HerdrOutput?

    var body: some View {
        Group {
            if let out = output, !(out.loading && out.lines.isEmpty) {
                if let error = out.error, out.lines.isEmpty {
                    ContentUnavailableView("No output", systemImage: "exclamationmark.triangle", description: Text(error))
                } else {
                    TerminalText(output: out)
                }
            } else {
                ProgressView("Reading the output…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// How close to the end the output must be, in points, to follow new lines.
private let followSlack: CGFloat = 48

/// The output in the layout of the phones: the rows that the agent wrapped
/// at the width of the terminal join, and they wrap again at the width of
/// the pane. Rules, boxes, and panels fit the pane. The view follows new
/// lines at the end. When the user scrolls up to read older lines, the view
/// stays there, and a button goes back to the newest lines.
private struct TerminalText: View {
    let output: HerdrOutput
    @State private var follow = true
    @State private var viewport: CGFloat = 0
    @State private var width: CGFloat = 0

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if output.truncated {
                        Text("Older lines are cut.").font(.caption.monospaced()).foregroundStyle(TermColors.dim)
                            .padding(.horizontal, termPad)
                    }
                    if let error = output.error {
                        Text(error).font(.caption).foregroundStyle(TermColors.red)
                            .padding(.horizontal, termPad)
                    }
                    if output.lines.isEmpty {
                        Text("No output yet.").font(TermColors.font).foregroundStyle(TermColors.dim)
                            .padding(.horizontal, termPad)
                    } else if width > 0 {
                        // The rows draw their own side padding, so the fill of a panel reaches both edges.
                        TermLinesView(lines: output.lines, width: width - scrollerWidth)
                            .textSelection(.enabled)
                    }
                    // The end of the output. Its place in the viewport tells
                    // whether the newest lines show.
                    Color.clear
                        .frame(height: 1)
                        .id("end")
                        .background(GeometryReader { g in
                            Color.clear.preference(key: EndOffset.self, value: g.frame(in: .named("output")).minY)
                        })
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 10)
            }
            .coordinateSpace(name: "output")
            .defaultScrollAnchor(.bottom)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear {
                        viewport = g.size.height
                        width = g.size.width
                        stayAtEnd(proxy)
                    }
                    .onChange(of: g.size) { _, size in
                        viewport = size.height
                        width = size.width
                        stayAtEnd(proxy)
                    }
            })
            .onPreferenceChange(EndOffset.self) { end in
                guard viewport > 0 else { return }
                follow = end <= viewport + followSlack
            }
            // New output scrolls to the newest lines, unless the user reads older ones.
            .onChange(of: output.text) {
                if follow { proxy.scrollTo("end", anchor: .bottom) }
            }
            .overlay(alignment: .bottomTrailing) {
                if !follow && !output.lines.isEmpty {
                    Button {
                        follow = true
                        withAnimation { proxy.scrollTo("end", anchor: .bottom) }
                    } label: {
                        Image(systemName: "arrow.down")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(TermColors.blue)
                            .frame(width: 32, height: 32)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(TermColors.background))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(TermColors.blue))
                    }
                    .buttonStyle(.plain)
                    .padding(10)
                    .help("Show the newest lines")
                    .accessibilityLabel("Show the newest lines")
                }
            }
        }
        .background(shape.fill(TermColors.background))
        .overlay(shape.strokeBorder(TermColors.border))
        .clipShape(shape)
    }
}

extension TerminalText {
    /// The width of a scroll bar that takes room from the rows. The scroll
    /// bars of macOS take no room unless the Mac always shows them, for
    /// example with a mouse.
    private var scrollerWidth: CGFloat {
        NSScroller.preferredScrollerStyle == .legacy ? NSScroller.scrollerWidth(for: .regular, scrollerStyle: .legacy) : 0
    }

    /// Keeps the newest lines on the screen after the width changes. The
    /// rows wrap again at the new width, and the first rows come 1 layout
    /// after the width is known, so the end moves.
    private func stayAtEnd(_ proxy: ScrollViewProxy) {
        guard follow else { return }
        DispatchQueue.main.async { proxy.scrollTo("end", anchor: .bottom) }
    }
}

private struct EndOffset: PreferenceKey {
    static let defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}
