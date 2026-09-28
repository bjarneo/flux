import FluxKit
import SwiftUI

@MainActor
enum MicFeature {
    /// The problem when a dictation would take the microphone from the
    /// stream, as on Android, or nil.
    static func dictationProblem(_ core: FluxCore) -> String? {
        core.plugin(MicPlugin.self)?.model.status.active == true ? "Stop Flux Microphone to dictate" : nil
    }
}

/// Opens the microphone screen of a Flux computer.
struct MicTile: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if device.isFlux, device.accepts(PacketType.fluxMic), let plugin = model.core.plugin(MicPlugin.self) {
            let live = plugin.model.status.active && plugin.model.status.deviceId == device.id
            FeatureTile("Microphone", systemImage: live ? "mic.fill" : "mic", tint: .orange,
                        subtitle: live ? "Live as Flux Microphone" : "For apps on the computer") {
                model.path.append(.feature(.mic(device.id)))
            }
            .disabled(!device.online && !live)
        }
    }
}

/// The microphone screen. Apps on the computer see this iPhone as Flux
/// Microphone while the stream runs. The stream keeps running when Flux
/// leaves the screen or the iPhone locks, until Stop.
struct MicScreen: View {
    @Environment(AppModel.self) private var model
    let deviceId: String

    var body: some View {
        Group {
            if let plugin = model.core.plugin(MicPlugin.self) {
                MicControls(plugin: plugin, mic: plugin.model, deviceId: deviceId)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Microphone")
        .navigationBarTitleDisplayMode(.inline)
    }
}

private struct MicControls: View {
    @Environment(AppModel.self) private var model
    let plugin: MicPlugin
    let mic: MicModel
    let deviceId: String

    private var name: String { model.device(deviceId)?.name ?? "the computer" }
    private var online: Bool { model.device(deviceId)?.online == true }
    /// True when the status belongs to this computer or to no computer.
    private var mine: Bool { mic.status.deviceId == nil || mic.status.deviceId == deviceId }
    private var active: Bool { mic.status.active && mic.status.deviceId == deviceId }

    private var statusText: String {
        if active || (mine && !mic.status.message.isEmpty) { return mic.status.message }
        return "Ready. Press Start to use this iPhone as a microphone on \(name)."
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                Image(systemName: active ? "mic.fill" : "mic")
                    .font(.system(size: 46, weight: .semibold))
                    .foregroundStyle(active ? Color.white : Color.orange)
                    .frame(width: 112, height: 112)
                    .background(Circle().fill(active ? Color.orange : Color.orange.opacity(0.15)))
                    .scaleEffect(1 + CGFloat(active ? mic.level : 0) * 0.25)
                    .animation(.linear(duration: 0.09), value: mic.level)
                    .accessibilityHidden(true)
                    .padding(.top, 24)
                if mic.permission == .denied {
                    denied
                } else {
                    controls
                }
            }
            .padding(.horizontal, 32)
            .frame(maxWidth: 480)
            .frame(maxWidth: .infinity)
        }
        .onAppear { plugin.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            plugin.refreshPermission()
        }
    }

    private var denied: some View {
        VStack(spacing: 12) {
            Text("Flux cannot use the microphone").font(.title3.weight(.semibold))
            Text("Allow the microphone for Flux in Settings, then start the microphone again.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("Open Settings") { AppSettings.open() }
                .buttonStyle(.borderedProminent)
        }
    }

    private var controls: some View {
        VStack(spacing: 18) {
            HStack(spacing: 8) {
                if active, mic.status.phase == .live { StatusPill(text: "Live", color: .red) }
                Text(statusText)
                    .font(.body)
                    .foregroundStyle(mine && mic.status.phase == .error ? .red : .primary)
                    .multilineTextAlignment(.center)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Input level").font(.caption).foregroundStyle(.secondary)
                ProgressView(value: Double(active ? mic.level : 0))
                    .progressViewStyle(.linear)
                    .tint(.orange)
                    .animation(.linear(duration: 0.09), value: mic.level)
            }
            .frame(maxWidth: 320)
            // The iPhone lists its inputs when a headset is connected.
            if mic.inputs.count > 1 {
                Picker("Input", selection: Binding(get: { mic.input }, set: { plugin.selectInput($0) })) {
                    Text("Automatic").tag("")
                    ForEach(mic.inputs) { Text($0.name).tag($0.id) }
                    if !mic.input.isEmpty && !mic.inputs.contains(where: { $0.id == mic.input }) {
                        Text("Disconnected Input").tag(mic.input)
                    }
                }
                .pickerStyle(.menu)
            }
            Button {
                if active { plugin.stop() } else { plugin.start(deviceId) }
            } label: {
                Label(active ? "Stop microphone" : "Start microphone", systemImage: active ? "stop.fill" : "mic.fill")
                    .font(.headline)
                    .frame(minWidth: 220, minHeight: 40)
            }
            .buttonStyle(.borderedProminent)
            .tint(active ? .red : .accentColor)
            .disabled(!active && !online)
            Text("Apps on \(name) see this iPhone as Flux Microphone. The stream keeps running when you leave Flux or lock the iPhone, until you press Stop.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }
}
