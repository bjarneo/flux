import FluxKit
import SwiftUI

/// The herdr agents of a computer on its dashboard: the blocked count, the
/// first agents, and the button that opens the agents window.
struct AgentsSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.fluxHerdr), let plugin = model.core.plugin(HerdrPlugin.self) {
            AgentsCard(device: device, herdr: plugin.model.states[device.id])
        }
    }
}

private struct AgentsCard: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot
    let herdr: HerdrState?

    /// The most agents that the card lists.
    private static let shown = 3

    var body: some View {
        let blocked = device.online ? herdr?.blocked ?? 0 : 0
        DashboardCard("Agents", systemImage: "brain", tint: .purple) {
            if blocked > 0 { StatusPill(text: "\(blocked) need\(blocked == 1 ? "s" : "") input", color: .red) }
        } content: {
            if let text = statusText {
                Text(text)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else if let herdr {
                let agents = herdr.sorted
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(agents.prefix(Self.shown)) { agent in
                        Button { open(agent.pane) } label: { AgentLine(agent: agent) }
                            .buttonStyle(.plain)
                    }
                    if agents.count > Self.shown {
                        Text("\(agents.count - Self.shown) more").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            Button("Open Agents…") { open(nil) }
                .disabled(!device.online)
                .help("Show the herdr agents of \(device.name), their output, and the replies")
        }
    }

    private var statusText: String? {
        guard device.online else { return "The agents show when \(device.name) is online." }
        guard let herdr else { return "Loading the agents of \(device.name)…" }
        if !herdr.enabled { return "Agent status is off on \(device.name). Set herdr = true in ~/.config/flux/config.toml." }
        if !herdr.running { return "herdr is not running on \(device.name)." }
        if herdr.agents.isEmpty { return "No agents yet. Start a coding agent in a herdr pane on \(device.name)." }
        return nil
    }

    private func open(_ pane: String?) {
        AgentsWindows.shared.show(device.id, pane: pane, app: model)
    }
}

/// 1 agent in the card: the status, the agent and project, and the title.
private struct AgentLine: View {
    let agent: HerdrAgent

    var body: some View {
        HStack(spacing: 8) {
            Circle().fill(agent.status.color).frame(width: 7, height: 7)
            Text("\(agent.agent) · \(agent.project.isEmpty ? agent.pane : agent.project)")
                .lineLimit(1)
            if !agent.title.isEmpty {
                Text(agent.title)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(agent.status.label)
                .font(.caption)
                .foregroundStyle(agent.status.color)
        }
        .contentShape(Rectangle())
    }
}

/// The menu bar item that opens the agents of a computer.
struct AgentsMenuItem: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.fluxHerdr), let plugin = model.core.plugin(HerdrPlugin.self) {
            let blocked = plugin.model.states[device.id]?.blocked ?? 0
            Button(blocked > 0 ? "Agents (\(blocked) Need\(blocked == 1 ? "s" : "") Input)…" : "Agents…") {
                AgentsWindows.shared.show(device.id, app: model)
            }
        }
    }
}

/// The agent notification switches. They apply to all computers.
struct AgentSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let plugin = model.core.plugin(HerdrPlugin.self) {
            AgentSettingsSection(model: plugin.model)
        }
    }
}

private struct AgentSettingsSection: View {
    @Bindable var model: HerdrModel

    var body: some View {
        Section {
            Toggle("Agent needs input", isOn: $model.inputAlerts)
            Toggle("Agent finished", isOn: $model.doneAlerts)
        } header: {
            Text("herdr agents")
        } footer: {
            Text("Notifications when a coding agent in herdr on a computer waits for an answer, or finishes its work. They apply to all computers.")
        }
    }
}
