import FluxKit
import SwiftUI

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if model.paired.isEmpty {
            Text("No paired computer")
        }
        ForEach(model.paired) { device in
            Section("\(device.name) — \(device.statusText)") {
                if device.online {
                    FeatureMenuItems(device: device)
                    Button("Ping") { model.core.plugin(PingPlugin.self)?.ping(device.id) }
                }
            }
        }
        Divider()
        Button("Open Flux") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        .keyboardShortcut("o")
        SettingsLink { Text("Settings…") }
            .keyboardShortcut(",")
        Divider()
        Button("Quit Flux") { NSApp.terminate(nil) }
            .keyboardShortcut("q")
    }
}
