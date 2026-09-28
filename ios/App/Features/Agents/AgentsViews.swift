import FluxKit
import SwiftUI

@MainActor
enum AgentsFeature {
    /// A tap on an agent notification opens the agent.
    static func didLaunch(model: AppModel) {
        model.core.plugin(HerdrPlugin.self)?.model.open = { [weak model] id, pane in
            model?.path = [.device(id), .feature(.agents(id)), .feature(.agent(id, pane))]
        }
    }

    /// The name of a computer in texts.
    static func name(_ model: AppModel, _ deviceId: String) -> String { model.device(deviceId)?.name ?? "the computer" }
}

/// Opens the herdr agents of a computer. The badge counts the agents that
/// need input.
struct AgentsTile: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.fluxHerdr), let plugin = model.core.plugin(HerdrPlugin.self) {
            let state = plugin.model.states[device.id]
            FeatureTile("Agents", systemImage: "brain", tint: .purple, subtitle: Self.subtitle(state, online: device.online),
                        badge: device.online ? state?.blocked ?? 0 : 0) {
                model.path.append(.feature(.agents(device.id)))
            }
            .disabled(!device.online)
        }
    }

    static func subtitle(_ state: HerdrState?, online: Bool) -> String {
        guard online, let state else { return "herdr coding agents" }
        if !state.enabled { return "Off" }
        if !state.running { return "herdr is not running" }
        if state.blocked > 0 { return state.blocked == 1 ? "1 needs input" : "\(state.blocked) need input" }
        let n = state.agents.count
        return n == 1 ? "1 agent" : "\(n) agents"
    }
}

/// The herdr agents of a computer. The agents that need input come first.
/// A tap opens the recent output of the agent. When the computer allows
/// terminals, they follow the agents. When the computer allows control,
/// the add button starts an agent or opens a terminal.
struct AgentsScreen: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    @State private var adding = false

    var body: some View {
        let device = model.device(deviceId)
        let online = device?.online == true
        let name = device?.name ?? "the computer"
        let plugin = model.core.plugin(HerdrPlugin.self)
        let herdr = plugin?.model.states[deviceId]
        Group {
            if !online {
                PaneNotReachable(name: name, what: "The agents")
            } else if let herdr {
                content(herdr, name: name)
            } else {
                ProgressView("Loading the agents of \(name)…")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Agents")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                if online {
                    Button { plugin?.request(deviceId) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                }
                if online, let herdr, herdr.running, herdr.control {
                    Button { adding = true } label: { Label("New agent or terminal", systemImage: "plus") }
                }
            }
        }
        .task(id: online) {
            if online { plugin?.request(deviceId) }
        }
        .sheet(isPresented: $adding) {
            NewPaneSheet(deviceId: deviceId) { what, pane in
                adding = false
                model.path.append(.feature(what == "terminal" ? .terminal(deviceId, pane) : .agent(deviceId, pane)))
            }
        }
    }

    @ViewBuilder
    private func content(_ herdr: HerdrState, name: String) -> some View {
        if !herdr.enabled {
            unavailable("Agent status is off",
                        "On \(name), set `herdr = true` in `~/.config/flux/config.toml`. Then run `systemctl --user reload fluxd`.")
        } else if !herdr.running {
            unavailable("herdr is not running", "Start herdr on \(name). Its coding agents show here.")
        } else if herdr.agents.isEmpty && herdr.panes.isEmpty {
            unavailable("No agents yet", herdr.control
                        ? "Tap + to start an agent on \(name), or start one in a herdr pane there."
                        : "Start a coding agent in a herdr pane on \(name). It shows here.")
        } else {
            List {
                Section {
                    ForEach(herdr.sorted) { agent in
                        NavigationLink(value: Route.feature(.agent(deviceId, agent.pane))) { AgentRow(agent: agent) }
                            .listRowBackground(agent.status == .blocked ? Color.red.opacity(0.12) : Color(.secondarySystemGroupedBackground))
                    }
                } footer: {
                    if !herdr.control {
                        Text(.init("To answer and start agents from this iPhone, set `herdr_control = true` on \(name)."))
                    }
                }
                if !herdr.panes.isEmpty {
                    Section("Terminals") {
                        ForEach(herdr.panes) { term in
                            NavigationLink(value: Route.feature(.terminal(deviceId, term.pane))) { TerminalRow(terminal: term) }
                        }
                    }
                }
            }
            .refreshable { model.core.plugin(HerdrPlugin.self)?.request(deviceId) }
        }
    }

    private func unavailable(_ title: String, _ text: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: "brain")
        } description: {
            Text(.init(text))
        } actions: {
            Button("Refresh") { model.core.plugin(HerdrPlugin.self)?.request(deviceId) }
        }
    }
}

/// 1 agent in the list: its status, project, workspace, and title.
private struct AgentRow: View {
    let agent: HerdrAgent

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
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
                    .font(.headline)
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
        .accessibilityElement(children: .combine)
    }
}

/// A herdr terminal: its folder, its workspace, and the terminal title.
private struct TerminalRow: View {
    let terminal: HerdrTerminal

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "terminal")
                .foregroundStyle(.green)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(terminal.project.isEmpty ? terminal.pane : terminal.project)
                        .font(.headline)
                        .lineLimit(1)
                    if !terminal.workspace.isEmpty && terminal.workspace != terminal.project {
                        Text(terminal.workspace)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    Text(terminal.pane)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.secondary)
                }
                Text(terminal.title.isEmpty ? "shell" : terminal.title)
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// The agent notification switches in the settings.
struct AgentSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let plugin = model.core.plugin(HerdrPlugin.self) {
            @Bindable var herdr = plugin.model
            Section {
                Toggle("Agent needs input", isOn: $herdr.inputAlerts)
                Toggle("Agent finished", isOn: $herdr.doneAlerts)
            } header: {
                Text("Agents")
            } footer: {
                Text("Flux notifies when a herdr agent on a computer waits for you or finishes. A tap opens the agent. The notifications come while Flux runs.")
            }
        }
    }
}
