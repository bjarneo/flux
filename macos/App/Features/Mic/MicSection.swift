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
        return "Ready to use this Mac as a microphone on \(device.name)."
    }

    var body: some View {
        DashboardCard("Microphone", systemImage: active ? "mic.fill" : "mic", tint: .red) {
            if mic.permission != .denied {
                Button(active ? "Stop" : "Start") {
                    if active { plugin.stop() } else { plugin.start(device.id) }
                }
                .buttonStyle(.borderedProminent)
                .tint(active ? .red : .accentColor)
                .controlSize(.small)
                .disabled(!active && !device.online)
            }
        } content: {
            if mic.permission == .denied {
                Label("Flux cannot use the microphone", systemImage: "mic.slash")
                Text("Allow Flux in System Settings > Privacy & Security > Microphone, then start the microphone again.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Open Privacy Settings") { NSWorkspace.shared.open(Self.privacySettings) }
            } else {
                HStack(spacing: 8) {
                    if active { StatusPill(text: "Live", color: .red) }
                    Text(statusText)
                        .font(.callout)
                        .foregroundStyle(mine && mic.status.phase == .error ? .red : .secondary)
                }
                if active {
                    ProgressView(value: Double(mic.level))
                        .progressViewStyle(.linear)
                        .tint(.red)
                        .animation(.linear(duration: 0.09), value: mic.level)
                }
                CardRow("Input") {
                    Picker("Input", selection: Binding(get: { mic.input }, set: { plugin.selectInput($0) })) {
                        Text("System Default").tag("")
                        ForEach(mic.inputs) { Text($0.name).tag($0.id) }
                        if !mic.input.isEmpty && !mic.inputs.contains(where: { $0.id == mic.input }) {
                            Text("Disconnected Input").tag(mic.input)
                        }
                    }
                    .labelsHidden()
                    .frame(maxWidth: 220, alignment: .trailing)
                }
                Text("Apps on \(device.name) see this Mac as Flux Microphone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
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
