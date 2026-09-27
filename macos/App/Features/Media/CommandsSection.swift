import FluxKit
import SwiftUI

/// The commands that a computer publishes.
struct CommandsSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.runCommandRequest), let plugin = model.core.plugin(RunCommandPlugin.self) {
            CommandList(device: device, plugin: plugin, commands: plugin.model.commands(device.id))
        }
    }
}

private struct CommandList: View {
    let device: DeviceSnapshot
    let plugin: RunCommandPlugin
    let commands: [RemoteCommand]?
    /// The command that ran last shows a check for a moment.
    @State private var ran: String?

    var body: some View {
        DashboardCard("Commands", systemImage: "terminal", tint: .orange) {
            Button { plugin.request(device.id) } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(.borderless)
                .help("Refresh the commands")
                .disabled(!device.online)
        } content: {
            if !device.online {
                Text("The commands show when \(device.name) is online.")
                    .foregroundStyle(.secondary)
            } else if let commands {
                if commands.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("No commands yet")
                        Text("On \(device.name), open Flux and add commands in Phone commands. They show here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                ForEach(commands) { c in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.name)
                            Text(c.command)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        Button {
                            plugin.run(device.id, c)
                            ran = c.key
                        } label: {
                            if ran == c.key {
                                Label("Done", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                            } else {
                                Label("Run", systemImage: "play.fill")
                            }
                        }
                        .help("Run \(c.name) on \(device.name)")
                    }
                }
            } else {
                HStack {
                    ProgressView().controlSize(.small)
                    Text("Loading the commands of \(device.name)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .task(id: device.online) {
            if device.online { plugin.request(device.id) }
        }
        .task(id: ran) {
            guard ran != nil else { return }
            try? await Task.sleep(for: .seconds(1.6))
            if !Task.isCancelled { ran = nil }
        }
    }
}
