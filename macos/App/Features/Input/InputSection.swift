import FluxKit
import SwiftUI

/// Opens the touchpad and the keyboard for a computer that takes remote
/// input. The card tells how to turn remote input on at the computer.
struct InputSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if RemoteInputPlugin.supported(device), let plugin = model.core.plugin(RemoteInputPlugin.self) {
            let on = plugin.model.isOn(device.id)
            DashboardCard("Touchpad and Keyboard", systemImage: "cursorarrow.motionlines", tint: .green) {
                StatusPill(text: on ? "On" : "Off", color: on ? .green : .secondary)
            } content: {
                if on {
                    Text("Control the pointer and the keys of \(device.name) with the trackpad, the mouse, and the keyboard of this Mac.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Button("Open Touchpad…") { TouchpadWindows.shared.open(device, app: model) }
                        .disabled(!device.online)
                        .help("Asks for Touch ID or the password of this Mac first")
                } else {
                    Text("Remote input is off on \(device.name).")
                    Text("On \(device.name), set `remote_input = true` in `~/.config/flux/config.toml`, then run `systemctl --user reload fluxd`.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }
        }
    }
}

/// Opens the touchpad from the menu bar.
struct InputMenuItem: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if RemoteInputPlugin.supported(device), let plugin = model.core.plugin(RemoteInputPlugin.self), plugin.model.isOn(device.id) {
            Button("Touchpad and Keyboard…") { TouchpadWindows.shared.open(device, app: model) }
        }
    }
}
