import FluxKit
import SwiftUI

/// The commands that a computer publishes for the iPhone.
struct CommandsTile: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.runCommandRequest), let plugin = model.core.plugin(RunCommandPlugin.self) {
            FeatureTile("Commands", systemImage: "terminal", tint: .orange, subtitle: Self.subtitle(plugin.model.commands(device.id))) {
                CommandsScreen(deviceId: device.id)
            }
            .task(id: device.online) {
                if device.online { plugin.request(device.id) }
            }
        }
    }

    static func subtitle(_ commands: [RemoteCommand]?) -> String {
        switch commands?.count {
        case nil: "Run commands on the computer"
        case 0?: "No commands yet"
        case 1?: "1 command"
        case let n?: "\(n) commands"
        }
    }
}

/// The list of commands. A tap runs one on the computer.
struct CommandsScreen: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    /// The command that ran last shows a check for a moment.
    @State private var ran: String?

    var body: some View {
        if let device = model.device(deviceId), let plugin = model.core.plugin(RunCommandPlugin.self) {
            let commands = plugin.model.commands(device.id)
            Group {
                if !device.online {
                    ContentUnavailableView("Not connected", systemImage: "wifi.slash",
                                           description: Text("The commands show when \(device.name) is online."))
                } else if let commands, commands.isEmpty {
                    ContentUnavailableView("No commands yet", systemImage: "terminal",
                                           description: Text("On \(device.name), add commands in Flux, or run flux-cli commands add. They show here."))
                } else if let commands {
                    List(commands) { c in
                        Button {
                            plugin.run(device.id, c)
                            ran = c.key
                        } label: {
                            HStack(spacing: 12) {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(c.name)
                                        .foregroundStyle(.primary)
                                    Text(c.command)
                                        .font(.caption.monospaced())
                                        .foregroundStyle(.secondary)
                                        .lineLimit(2)
                                }
                                Spacer(minLength: 8)
                                Image(systemName: ran == c.key ? "checkmark.circle.fill" : "play.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(ran == c.key ? Color.green : Color.accentColor)
                                    .contentTransition(.symbolEffect(.replace))
                                    .accessibilityHidden(true)
                            }
                        }
                        .tint(.primary)
                        .accessibilityHint("Runs the command on \(device.name)")
                    }
                    .refreshable { plugin.request(device.id) }
                } else {
                    ProgressView("Loading the commands of \(device.name)")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Commands")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Refresh", systemImage: "arrow.clockwise") { plugin.request(device.id) }
                        .disabled(!device.online)
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
}
