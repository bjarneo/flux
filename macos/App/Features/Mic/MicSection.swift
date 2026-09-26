import AppKit
import FluxKit
import SwiftUI

/// This Mac as a microphone for a paired Flux computer.
struct MicSection: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.isFlux, let plugin = model.core.plugin(MicPlugin.self) {
            MicControls(plugin: plugin, mic: plugin.model, device: device)
        }
    }
}

private struct MicControls: View {
    let plugin: MicPlugin
    let mic: MicModel
    let device: DeviceSnapshot

    private static let privacySettings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!

    /// True when the status belongs to this computer or to no computer.
    private var mine: Bool { mic.status.deviceId == nil || mic.status.deviceId == device.id }
    private var active: Bool { mic.status.active && mic.status.deviceId == device.id }

    private var statusText: String {
        if active || (mine && !mic.status.message.isEmpty) { return mic.status.message }
        return "Ready. Press Start to use this Mac as a microphone on \(device.name)."
    }

    var body: some View {
        Section {
            if mic.permission == .denied {
                Label("Flux cannot use the microphone", systemImage: "mic.slash")
                Text("Allow Flux in System Settings > Privacy & Security > Microphone, then start the microphone again.")
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") { NSWorkspace.shared.open(Self.privacySettings) }
            } else {
                HStack {
                    Label(statusText, systemImage: active ? "mic.fill" : "mic")
                        .foregroundStyle(mine && mic.status.phase == .error ? .red : .primary)
                    Spacer()
                    Button(active ? "Stop Microphone" : "Start Microphone") {
                        if active { plugin.stop() } else { plugin.start(device.id) }
                    }
                    .disabled(!active && !device.online)
                }
                Picker("Input", selection: Binding(get: { mic.input }, set: { plugin.selectInput($0) })) {
                    Text("System Default").tag("")
                    ForEach(mic.inputs) { Text($0.name).tag($0.id) }
                    if !mic.input.isEmpty && !mic.inputs.contains(where: { $0.id == mic.input }) {
                        Text("Disconnected Input").tag(mic.input)
                    }
                }
                LabeledContent("Input level") {
                    ProgressView(value: active ? Double(mic.level) : 0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 220)
                        .animation(.linear(duration: 0.09), value: mic.level)
                }
            }
        } header: {
            Text("Microphone")
        } footer: {
            Text("Apps on \(device.name) see this Mac as Flux Microphone.")
        }
        .onAppear { plugin.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            plugin.refreshPermission()
        }
    }
}

/// Starts or stops the microphone from the menu bar.
struct MicMenuItem: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.accepts(PacketType.fluxMic), let plugin = model.core.plugin(MicPlugin.self) {
            let status = plugin.model.status
            if status.active && status.deviceId == device.id {
                Button("Stop Microphone") { plugin.stop() }
            } else {
                Button("Start Microphone") { plugin.start(device.id) }
            }
        }
    }
}
