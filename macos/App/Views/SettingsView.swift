import FluxKit
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        @Bindable var model = model
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
                    Picker("Theme", selection: $model.themeMode) {
                        ForEach(ThemeMode.allCases) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.radioGroup)
                    Text("Computer: \(computerLine)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } footer: {
                    Text("Computer draws the Omarchy theme of the computer in scope. System follows the appearance of macOS with Tokyo Night. The theme also picks the light or dark Dock icon. Finder keeps the dark icon.")
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("General", systemImage: "gearshape") }

            Form { FeatureSettings() }
                .formStyle(.grouped)
                .tabItem { Label("Features", systemImage: "square.grid.2x2") }
        }
        .frame(width: 520, height: 520)
    }

    /// The theme that the Computer choice draws now, and the computer that sent it.
    private var computerLine: String {
        let theme = model.computerTheme
        return ThemeMode.computerLine(
            theme: theme,
            themeComputer: theme.flatMap { t in model.state.devices.first { $0.id == t.deviceId }?.name },
            scopeComputer: model.pairedDevice(model.scope)?.name,
            systemDark: systemDark
        )
    }

    /// The light or dark mode of macOS. While the theme sets the mode of
    /// the windows, the window cannot tell it, so the setting of macOS does.
    private var systemDark: Bool {
        if model.nightMode == .system { return scheme == .dark }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
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
