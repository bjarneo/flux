import AppKit
import FluxKit
import SwiftUI

/// The remote desktop window: the video, a bar with the monitor and the
/// panel buttons, the Omarchy panel at the side, and the keys at the bottom.
struct DesktopView: View {
    @Bindable var controller: DesktopController

    var body: some View {
        Group {
            if let d = controller.device, d.paired {
                if !d.online {
                    ContentUnavailableView("\(d.name) is offline", systemImage: "wifi.slash",
                                           description: Text("The screen shows when \(d.name) is connected."))
                } else if !DesktopPlugin.supported(d) {
                    ContentUnavailableView("Update Flux on \(d.name)", systemImage: "display",
                                           description: Text("This version of Flux on \(d.name) does not stream its screen."))
                } else if !controller.desktopOn {
                    ContentUnavailableView("Remote desktop is off", systemImage: "display",
                                           description: Text("On \(d.name), set `remote_desktop = true` in `~/.config/flux/config.toml`, then run `systemctl --user reload fluxd`."))
                } else {
                    content
                }
            } else {
                ContentUnavailableView("\(controller.name) is not paired", systemImage: "link",
                                       description: Text("Pair this Mac with \(controller.name) again to show its screen."))
            }
        }
        .frame(minWidth: 640, minHeight: 420)
        .onChange(of: controller.ready) { _, ready in
            if ready { controller.start() } else { controller.stop() }
        }
        .onChange(of: controller.control) { _, control in
            if !control, controller.panel != nil { controller.panel = nil }
        }
    }

    private var content: some View {
        VStack(spacing: 0) {
            DesktopBar(controller: controller)
            Divider()
            HStack(spacing: 0) {
                ZStack {
                    DesktopVideo(controller: controller)
                    StreamState(controller: controller)
                }
                if controller.panel == .omarchy && controller.control {
                    Divider()
                    OmarchyPanel(controller: controller)
                        .frame(width: 300)
                }
            }
            if controller.panel == .keys && controller.control {
                Divider()
                DesktopKeys(controller: controller)
                    .padding(12)
            }
        }
    }
}

/// The bar over the video: the state, the monitor, and the panel buttons.
private struct DesktopBar: View {
    @Bindable var controller: DesktopController

    var body: some View {
        let status = controller.status
        HStack(spacing: 10) {
            if controller.live {
                StatusPill(text: "Live", color: .green)
            }
            if !controller.control {
                StatusPill(text: "View only", color: .secondary)
                    .help("To control \(controller.name), set remote_input = true on it, then run systemctl --user reload fluxd.")
            }
            if controller.viewOnlyNotice && !controller.control {
                Text("To control \(controller.name), set `remote_input = true` on it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            Button(controller.audioOn ? "Audio off" : "Audio on") { controller.toggleAudio() }
            if controller.audioOn {
                Button(controller.audioVolume == 0 ? "Unmute" : "Mute") { controller.toggleMute() }
                Slider(value: $controller.audioVolume, in: 0...1).frame(width: 90).accessibilityLabel("Remote audio volume")
            }
            if let status, status.monitors.count > 1 {
                Picker("Monitor", selection: Binding(get: { status.monitor }, set: { controller.show(monitor: $0) })) {
                    ForEach(status.monitors, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .fixedSize()
                .help("Show another monitor of \(controller.name)")
            }
            if controller.control {
                if controller.shortcutsSupported {
                    PanelButton(systemImage: "square.grid.2x2", help: "Show the Omarchy panel", on: controller.panel == .omarchy) {
                        controller.toggle(.omarchy)
                    }
                }
                PanelButton(systemImage: "keyboard", help: "Show the keys", on: controller.panel == .keys) { controller.toggle(.keys) }
                let dictating = controller.dictation.phase != .idle
                PanelButton(systemImage: dictating ? "mic.fill" : "mic", help: dictating ? "Stop the dictation" : "Dictate on \(controller.name)",
                            on: dictating, tint: .red) {
                    if dictating { controller.dictation.stop() } else { controller.dictate() }
                }
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }
}

/// A button that shows or hides a panel. It has the tint while it is on.
private struct PanelButton: View {
    let systemImage: String
    let help: String
    let on: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .frame(width: 22, height: 18)
                .foregroundStyle(on ? tint : .secondary)
        }
        .buttonStyle(.bordered)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// The state of the stream over the video: a wait, an error, or a stop.
private struct StreamState: View {
    let controller: DesktopController

    var body: some View {
        let status = controller.status
        if status == nil || status?.phase == .error || status?.phase == .idle {
            VStack(spacing: 12) {
                Image(systemName: "display").font(.largeTitle).foregroundStyle(.secondary)
                Text(status?.phase == .error ? "The screen does not show" : "The stream stopped").font(.headline)
                Text(message(status)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Start Again") { controller.start() }
            }
            .padding(32)
            .frame(maxWidth: 460)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        } else if !controller.live {
            VStack(spacing: 12) {
                ProgressView()
                Text(status?.message ?? "Connecting to \(controller.name)…").foregroundStyle(.secondary)
            }
            .padding(24)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(.regularMaterial))
        }
    }

    /// The computer writes its errors in lower case.
    private func message(_ status: DesktopModel.Status?) -> String {
        guard let text = status?.message, let first = text.first else { return "Start the stream again." }
        return first.uppercased() + text.dropFirst()
    }
}

/// The keys under the video: the key rows, the text field, and the mic key.
private struct DesktopKeys: View {
    @Bindable var controller: DesktopController
    @State private var picking = false
    @State private var canDictate = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RemoteKeyRows(target: controller)
            DictationBar(
                dictation: controller.dictation,
                canDictate: canDictate,
                onStart: controller.dictate,
                onLanguage: {
                    controller.dictation.stopNow()
                    picking = true
                },
                field: {
                    RemoteTypeField(target: controller)
                },
                send: {
                    Button { controller.key(.enter) } label: {
                        Image(systemName: "return")
                            .frame(width: DictationLayout.keySize - 12, height: DictationLayout.keySize - 12)
                    }
                    .buttonStyle(.bordered)
                    .help("Press Enter on \(controller.name)")
                    .accessibilityLabel("Enter")
                }
            )
            if let problem = controller.voiceError ?? controller.dictation.error {
                HStack(spacing: 10) {
                    Text(problem).font(.caption).foregroundStyle(.red)
                    Spacer(minLength: 0)
                    if problem == controller.dictation.error && controller.dictation.languageError {
                        Button("Choose a Language") { picking = true }
                            .buttonStyle(.link)
                            .font(.caption)
                    }
                }
            }
        }
        .task { canDictate = await Task.detached { Dictation.available }.value }
        .sheet(isPresented: $picking) {
            if let herdr = controller.app.core.plugin(HerdrPlugin.self) {
                LanguagePicker(selected: herdr.model.dictationLanguage) { tag in
                    herdr.model.dictationLanguage = tag
                    picking = false
                    controller.dictate()
                } onCancel: {
                    picking = false
                }
            }
        }
    }
}
