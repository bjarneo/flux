import FluxKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.automatic

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
                LoginItemSection()
                Section {
                    Picker("Appearance", selection: $appearance) {
                        ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented)
                } footer: {
                    Text("Sets the windows and the Dock icon. Automatic follows the appearance of macOS. Finder keeps the dark icon.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form { FeatureSettings() }
                .formStyle(.grouped)
                .tabItem { Label("Features", systemImage: "square.grid.2x2") }
        }
        .frame(width: 520, height: 520)
        .onChange(of: appearance) { AppearanceController.shared.apply() }
    }
}

/// Open at login, with the main app as the login item. macOS can ask the
/// user to allow Flux in System Settings > General > Login Items.
private struct LoginItemSection: View {
    @State private var status = SMAppService.mainApp.status
    @State private var error: String?

    var body: some View {
        Section {
            Toggle("Open at login", isOn: Binding(get: { status == .enabled || status == .requiresApproval }, set: { setOpenAtLogin($0) }))
            if status == .requiresApproval {
                LabeledContent("Allow Flux in Login Items") {
                    Button("Open Login Items…") { SMAppService.openSystemSettingsLoginItems() }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.red)
                    .font(.caption)
            }
        } footer: {
            Text("Flux opens when you log in, so that the clipboard syncs without a click. After you close the window, Flux keeps running in the menu bar.")
        }
        .onAppear { status = SMAppService.mainApp.status }
    }

    private func setOpenAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            error = nil
        } catch {
            self.error = "macOS did not change the login item: \(error.localizedDescription)"
        }
        status = SMAppService.mainApp.status
    }
}
