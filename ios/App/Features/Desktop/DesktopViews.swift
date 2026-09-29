import FluxKit
import SwiftUI
import UIKit

/// Opens the screen of a computer that streams it. The screen can show
/// private content, so the tile asks for Face ID or the passcode first,
/// like the Android app.
struct DesktopTile: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        if DesktopPlugin.supported(device), let input = model.core.plugin(RemoteInputPlugin.self) {
            let on = input.model.isDesktopOn(device.id)
            FeatureTile("Remote desktop", systemImage: "display", tint: .teal, subtitle: Self.subtitle(desktop: on, input: input.model.isOn(device.id))) {
                let route = Route.feature(.desktop(device.id))
                guard on else { return model.path.append(route) }
                ReplyLock.run(reason: "Show the screen of \(device.name).") {
                    model.path.append(route)
                } onError: { model.show($0) }
            }
            .disabled(!device.online)
        }
    }

    static func subtitle(desktop: Bool, input: Bool) -> String {
        if !desktop { return "Off" }
        return input ? "Show and control the screen" : "View only"
    }
}

/// The screen of the computer on the iPhone. In portrait, the panels show
/// under the video. In landscape, the bars hide, a rail at the side holds
/// the buttons, and the panels show at the right of the video.
struct DesktopScreen: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    @State private var controller: DesktopController?

    var body: some View {
        Group {
            if let d = model.device(deviceId), let plugin = model.core.plugin(DesktopPlugin.self),
               let input = model.core.plugin(RemoteInputPlugin.self) {
                if !d.online {
                    unavailable("\(d.name) is not reachable", "wifi.slash", "The screen shows when \(d.name) is connected.")
                } else if !DesktopPlugin.supported(d) {
                    unavailable("Update Flux on \(d.name)", "display", "This version of Flux on \(d.name) does not stream its screen.")
                } else if !input.model.isDesktopOn(d.id) {
                    unavailable("Remote desktop is off", "display",
                                "On \(d.name), set `remote_desktop = true` in `~/.config/flux/config.toml`, then run `systemctl --user reload fluxd`.")
                } else {
                    // Remote desktop can turn on while the screen is open, after the tile.
                    UnlockGate(reason: "Show the screen of \(d.name).") {
                        if let controller {
                            DesktopContent(controller: controller)
                        } else {
                            Color.black.onAppear { controller = DesktopController(device: d, app: model, plugin: plugin, input: input) }
                        }
                    }
                }
            }
        }
        .onDisappear { controller?.close() }
    }

    private func unavailable(_ title: String, _ symbol: String, _ text: String) -> some View {
        ContentUnavailableView(title, systemImage: symbol, description: Text(.init(text)))
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Remote desktop")
            .navigationBarTitleDisplayMode(.inline)
    }
}

/// The video, the buttons, and the panels.
private struct DesktopContent: View {
    @Bindable var controller: DesktopController
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        GeometryReader { geo in
            let wide = geo.size.width > geo.size.height
            let panel = controller.control ? controller.panel : nil
            // 1 layout for both orientations, so that the video keeps its
            // view, and its display layer, when the iPhone turns.
            let layout = wide ? AnyLayout(HStackLayout(spacing: 0)) : AnyLayout(VStackLayout(spacing: 0))
            layout {
                if wide {
                    VStack(spacing: 10) {
                        RailButton(systemImage: "chevron.backward", name: "Back", on: false) { dismiss() }
                        Spacer(minLength: 0)
                        DesktopButtons(controller: controller, showsMonitor: true)
                    }
                    .padding(8)
                }
                video(hint: !wide && panel == nil, wide: wide)
                if let panel {
                    panelView(panel)
                        .frame(width: wide ? 300 : nil)
                        .frame(maxHeight: !wide && panel == .omarchy ? 380 : nil)
                }
            }
            .background(Color(.systemGroupedBackground))
            .toolbar(wide ? .hidden : .automatic, for: .navigationBar)
            .toolbar {
                if !wide {
                    ToolbarItemGroup(placement: .topBarTrailing) {
                        DesktopButtons(controller: controller, showsMonitor: false)
                    }
                }
            }
            .statusBarHidden(wide)
            .persistentSystemOverlays(wide ? .hidden : .automatic)
        }
        .navigationTitle("Remote desktop")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear { if controller.status?.active != true { controller.start() } }
        .onChange(of: controller.ready) { _, ready in
            if ready { controller.start() } else { controller.stop() }
        }
        .onChange(of: controller.control) { _, control in
            if !control { controller.panel = nil }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .background: controller.pause()
            case .active: controller.resume()
            default: break
            }
        }
        // The screen stays on while the stream shows.
        .onChange(of: controller.live, initial: true) { _, live in UIApplication.shared.isIdleTimerDisabled = live }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }

    private func video(hint: Bool, wide: Bool) -> some View {
        VStack(spacing: 0) {
            ZStack(alignment: .topTrailing) {
                DesktopVideoSurface(controller: controller)
                StreamState(controller: controller)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                // In portrait the bar has no room for the monitor, so it shows over the video.
                if !wide {
                    MonitorChip(controller: controller)
                        .padding(8)
                }
            }
            if hint {
                Text(controller.control
                     ? "Tap clicks · hold for the right button · hold, then move to drag\n2 fingers scroll · pinch zooms · 1 finger moves the zoomed view"
                     : "View only · pinch zooms · 1 finger moves the zoomed view")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
            }
        }
    }

    @ViewBuilder
    private func panelView(_ panel: DesktopController.Panel) -> some View {
        switch panel {
        case .omarchy:
            OmarchyPanel(controller: controller)
        case .keys:
            DesktopKeys(controller: controller)
                .padding(10)
        }
    }
}

/// The name of the monitor that shows, when the computer has more than 1.
/// A tap shows the next monitor.
private struct MonitorChip: View {
    let controller: DesktopController

    var body: some View {
        if let status = controller.status, let next = controller.nextMonitor {
            Button { controller.showNextMonitor() } label: {
                Text(status.monitor)
                    .font(.system(.caption, design: .monospaced, weight: .medium))
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 7)
                    .background(Capsule().fill(.regularMaterial))
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Monitor \(status.monitor)")
            .accessibilityHint("Shows \(next)")
        }
    }
}

/// The buttons of the panels and the dictation, and in landscape the monitor chip.
private struct DesktopButtons: View {
    let controller: DesktopController
    let showsMonitor: Bool

    var body: some View {
        if showsMonitor {
            MonitorChip(controller: controller)
        }
        if controller.control {
            if controller.shortcutsSupported {
                RailButton(systemImage: "square.grid.2x2", name: "Omarchy panel", on: controller.panel == .omarchy) { controller.toggle(.omarchy) }
            }
            RailButton(systemImage: "keyboard", name: "Keys", on: controller.panel == .keys) { controller.toggle(.keys) }
            let dictating = controller.dictation.phase != .idle
            RailButton(systemImage: dictating ? "mic.fill" : "mic", name: dictating ? "Stop the dictation" : "Dictate",
                       on: dictating, tint: .red) {
                if dictating { controller.dictation.stop() } else { controller.dictate() }
            }
        }
    }
}

/// A button that shows or hides a panel. It has the tint while it is on.
private struct RailButton: View {
    let systemImage: String
    let name: String
    let on: Bool
    var tint: Color = .accentColor
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .foregroundStyle(on ? tint : .secondary)
                .frame(width: 36, height: 36)
                .background(RoundedRectangle(cornerRadius: 9, style: .continuous).fill(on ? tint.opacity(0.15) : Color(.tertiarySystemFill)))
                .overlay(RoundedRectangle(cornerRadius: 9, style: .continuous).strokeBorder(on ? tint : .clear))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(name)
        .accessibilityAddTraits(on ? .isSelected : [])
    }
}

/// The state of the stream over the video: a wait, an error, or a stop.
private struct StreamState: View {
    let controller: DesktopController

    var body: some View {
        let status = controller.status
        if let status, status.phase == .error || status.phase == .idle {
            VStack(spacing: 12) {
                Image(systemName: "display").font(.largeTitle).foregroundStyle(.secondary)
                Text(status.phase == .error ? "The screen does not show" : "The stream stopped").font(.headline)
                Text(Self.message(status.message)).multilineTextAlignment(.center).foregroundStyle(.secondary)
                Button("Start Again") { controller.start() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!controller.ready)
            }
            .padding(24)
            .frame(maxWidth: 420)
            .background(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.regularMaterial))
            .padding(16)
        } else if !controller.live {
            VStack(spacing: 12) {
                ProgressView().tint(.white)
                Text(status?.message.isEmpty == false ? status?.message ?? "" : "Connecting to \(controller.name)…")
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    /// The computer writes its errors in lower case.
    static func message(_ text: String) -> String {
        guard let first = text.first else { return "Start the stream again." }
        return first.uppercased() + text.dropFirst()
    }
}

/// The keys under the video: the key rows, the text field, the mic key, and Enter.
private struct DesktopKeys: View {
    @Bindable var controller: DesktopController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            KeyRows(keys: controller.keys)
            HStack(spacing: 8) {
                TypeField(keys: controller.keys, placeholder: "Type on \(controller.name)")
                    .frame(height: 44)
                    .padding(.horizontal, 12)
                    .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                    .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color(.separator).opacity(0.5)))
                let dictating = controller.dictation.phase != .idle
                Button {
                    if dictating { controller.dictation.stop() } else { controller.dictate() }
                } label: {
                    Image(systemName: dictating ? "stop.fill" : "mic")
                        .foregroundStyle(dictating ? .red : .secondary)
                        .frame(width: 44, height: 44)
                        .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(Color(.secondarySystemGroupedBackground)))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(dictating ? "Stop the dictation" : "Dictate")
                PadKey(label: "⏎", name: "Enter", height: 44) { controller.keys.key(.enter) }
                    .frame(width: 44)
            }
            if controller.dictation.phase != .idle {
                Text(controller.dictation.pending.isEmpty && controller.dictation.settled.isEmpty
                     ? "Listening…" : controller.dictation.settled + " " + controller.dictation.pending)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
            if let problem = controller.voiceError ?? controller.dictation.error {
                Text(problem).font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
