import FluxKit
import SwiftUI

/// The Omarchy panel of 1 computer on its own screen, from the master tool
/// of Control: workspaces, windows, and the key bindings. The computer
/// runs each action in Hyprland. The panel sends input, so it asks for
/// Face ID or the passcode first, like the touchpad. No stream starts.
struct OmarchyPanelScreen: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    @State private var controller: DesktopController?

    var body: some View {
        Group {
            if let d = model.device(deviceId), let plugin = model.core.plugin(DesktopPlugin.self),
               let input = model.core.plugin(RemoteInputPlugin.self) {
                if !d.online {
                    unavailable("\(d.name) is not reachable", "wifi.slash", "The panel shows when \(d.name) is connected.")
                } else if !DesktopPlugin.shortcutsSupported(d) {
                    unavailable("Update Flux on \(d.name)", "square.grid.3x3",
                                "This version of Flux on \(d.name) does not send its workspaces and key bindings.")
                } else if !input.model.isOn(d.id) {
                    unavailable("Remote input is off", "square.grid.3x3",
                                "On \(d.name), set `remote_input = true` in `~/.config/flux/config.toml`, then run `systemctl --user reload fluxd`.")
                } else {
                    // Remote input can turn on while the screen is open, after the tool.
                    UnlockGate(reason: "Use the Omarchy panel of \(d.name).") {
                        if let controller {
                            OmarchyPanel(controller: controller)
                        } else {
                            Color.clear.onAppear {
                                controller = DesktopController(device: d, app: model, plugin: plugin, input: input)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationTitle("Omarchy panel")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { controller?.close() }
    }

    private func unavailable(_ title: String, _ symbol: String, _ text: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(.init(text)))
    }
}
