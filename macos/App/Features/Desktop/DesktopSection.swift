import FluxKit
import SwiftUI

/// Opens the screen of a computer that streams it. The card tells how to
/// turn the remote desktop on at the computer.
struct DesktopSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if DesktopPlugin.supported(device), let input = model.core.plugin(RemoteInputPlugin.self) {
            let on = input.model.isDesktopOn(device.id)
            DashboardCard("Remote Desktop", systemImage: "display", tint: .teal) {
                StatusPill(text: on ? "On" : "Off", color: on ? .green : .secondary)
            } content: {
                if on {
                    Text("Show the screen of \(device.name) in a window, and control it with the mouse and the keyboard of this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    if !input.model.isOn(device.id) {
                        Text("View only. To control \(device.name), set `remote_input = true` on it.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("Open Remote Desktop…") { DesktopWindows.shared.open(device, app: model) }
                        .disabled(!device.online)
                        .help("Asks for Touch ID or the password of this Mac first")
                } else {
                    Text("Remote desktop is off on \(device.name).")
                    Text("On \(device.name), set `remote_desktop = true` in `~/.config/flux/config.toml`, then run `systemctl --user reload fluxd`.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// Opens the remote desktop from the menu bar.
struct DesktopMenuItem: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if DesktopPlugin.supported(device), let input = model.core.plugin(RemoteInputPlugin.self), input.model.isDesktopOn(device.id) {
            Button("Remote Desktop…") { DesktopWindows.shared.open(device, app: model) }
        }
    }
}
