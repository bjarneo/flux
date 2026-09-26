import FluxKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        TabView {
            Form {
                Section {
                    Toggle("Flux is on", isOn: Binding(
                        get: { model.state.enabled },
                        set: { model.core.enabled = $0 }
                    ))
                    LabeledContent("Name", value: model.state.deviceName)
                    LabeledContent("Device ID") { Text(model.state.deviceId).textSelection(.enabled).font(.caption.monospaced()) }
                    LabeledContent("Link port", value: model.state.tcpPort == 0 ? "–" : String(model.state.tcpPort))
                    if !model.state.listeningUdp {
                        Text("Another app uses UDP port 1716. Flux still announces itself and computers can connect.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } footer: {
                    Text("Change the name in System Settings > General > Sharing.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form { FeatureSettings() }
                .formStyle(.grouped)
                .tabItem { Label("Features", systemImage: "square.grid.2x2") }
        }
        .frame(width: 520, height: 460)
    }
}
