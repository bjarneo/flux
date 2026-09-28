import FluxKit
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @AppStorage(AppAppearance.key) private var appearance = AppAppearance.automatic
    @State private var name = ""
    @FocusState private var editingName: Bool

    var body: some View {
        Form {
            Section {
                LabeledContent("Name") {
                    HStack(spacing: 6) {
                        TextField("iPhone", text: $name)
                            .multilineTextAlignment(.trailing)
                            .focused($editingName)
                            .submitLabel(.done)
                            .textInputAutocapitalization(.words)
                            .autocorrectionDisabled()
                            .onSubmit(saveName)
                        if editingName && !name.isEmpty {
                            Button {
                                name = ""
                            } label: {
                                Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Clear the name")
                        }
                    }
                }
                Toggle("Flux is on", isOn: Binding(
                    get: { model.state.enabled },
                    set: { model.core.enabled = $0 }
                ))
            } header: {
                Text("This iPhone")
            } footer: {
                Text("Computers show this name. While Flux is off, it uses no network and computers do not see this iPhone.")
            }
            Section {
                Picker("Appearance", selection: $appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            } header: {
                Text("Appearance")
            } footer: {
                Text("Automatic follows the appearance of iOS.")
            }
            FeatureSettings()
            Section("About") {
                LabeledContent("Device ID") {
                    Text(model.state.deviceId)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                LabeledContent("Link port", value: model.state.tcpPort == 0 ? "–" : String(model.state.tcpPort))
                LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
            }
        }
        .navigationTitle("Settings")
        .onAppear { name = model.state.deviceName }
        .onChange(of: editingName) { _, editing in
            if !editing { saveName() }
        }
        .onDisappear(perform: saveName)
    }

    /// Stores the name when it changed. An empty name goes back to "iPhone".
    private func saveName() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != model.state.deviceName else { return }
        model.core.setDeviceName(trimmed)
        name = model.core.deviceName
    }
}
