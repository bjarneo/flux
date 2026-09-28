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
/// when the status changes, and every 5 seconds while the agent works.
private struct AgentDetail: View {
    let model: AgentsWindowModel
    let pane: String
    let name: String

    private struct Refresh: Equatable {
        var online: Bool
        var status: AgentStatus?
    }

    var body: some View {
        let agent = model.herdr?.agent(pane)
        let out = model.plugin.model.output(model.deviceId, pane: pane)
        VStack(alignment: .leading, spacing: 12) {
            if let agent {
                AgentHeader(agent: agent, loading: out?.loading == true && !(out?.lines.isEmpty ?? true)) {
                    model.plugin.read(model.deviceId, pane: pane)
                }
                AgentOutput(output: out)
                if model.herdr?.control == true {
                    ReplyControls(model: model, agent: agent, output: out, name: name)
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
        .task(id: Refresh(online: model.device?.online == true, status: agent?.status)) {
            guard model.device?.online == true, agent != nil else { return }
            model.plugin.read(model.deviceId, pane: pane)
            while agent?.status == .working {
                try? await Task.sleep(for: workingRefresh)
                if Task.isCancelled { return }
                model.plugin.read(model.deviceId, pane: pane)
            }
        }
        .onDisappear { model.plugin.closeOutput(model.deviceId, pane: pane) }
    }
}

private struct AgentHeader: View {
    let agent: HerdrAgent
    let loading: Bool
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

private struct TerminalText: View {
    let output: HerdrOutput

    var body: some View {
        let text = TermColors.attributed(output.lines)
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    if output.truncated {
                        Text("Older lines are cut.").font(.caption.monospaced()).foregroundStyle(TermColors.dim)
                    }
                    if let error = output.error {
                        Text(error).font(.caption).foregroundStyle(TermColors.red)
                    }
                    if output.lines.isEmpty {
                        Text("No output yet.").font(TermColors.font).foregroundStyle(TermColors.dim)
                    } else {
                        Text(text)
                            .font(TermColors.font)
                            .foregroundStyle(TermColors.text)
                            .lineSpacing(2)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Color.clear.frame(height: 1).id("end")
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
            }
            .defaultScrollAnchor(.bottom)
            // New output scrolls to the newest lines.
            .onChange(of: output.text) { proxy.scrollTo("end", anchor: .bottom) }
        }
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(TermColors.background))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(TermColors.border))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}
