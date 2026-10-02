import FluxKit
import SwiftUI
import UIKit

/// The Computers destination: this iPhone, the paired computers, the
/// computers to pair, and the settings of the app. A tap on a paired
/// computer makes it the scope, and a tap on the computer in scope shows
/// all computers again. The page of a computer holds its approval setup. A
/// pull down searches again.
struct ComputersView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.colorScheme) private var scheme
    @State private var unpairing: DeviceSnapshot?
    @State private var turningOff = false

    static let localNetworkText = "Flux needs Local Network access to find and reach computers. Turn on Local Network for Flux in Settings."

    var body: some View {
        let paired = model.paired
        let available = model.available.filter { $0.online }
        ScrollView {
            VStack(alignment: .leading, spacing: TiledMetrics.gap) {
                if !model.state.enabled {
                    StateTile(icon: "power", title: "Flux is off",
                              text: "Flux uses no network while it is off, and computers do not see this iPhone.") {
                        Button("Turn on") { model.core.enabled = true }
                            .buttonStyle(FluxButtonStyle(kind: .filled))
                    }
                } else if model.state.localNetworkDenied && !model.state.devices.contains(where: { $0.online }) {
                    StateTile(icon: "wifi.exclamationmark", title: "Local Network is off", text: Self.localNetworkText) {
                        Button("Open Settings", action: openSettings)
                            .buttonStyle(FluxButtonStyle(kind: .filled))
                    }
                }
                phoneRow
                SectionLabel("Paired")
                if paired.isEmpty {
                    Text("No computer is paired. Pair one below. A paired computer connects by itself.")
                        .font(.subheadline)
                        .foregroundStyle(tn.sub)
                        .padding(.horizontal, 4)
                }
                ForEach(paired) { d in
                    PairedComputerRow(device: d, inScope: model.scope == d.id) {
                        model.setScope(model.scope == d.id ? nil : d.id)
                    } onUnpair: {
                        unpairing = d
                    }
                }
                SectionLabel("Available")
                ForEach(available) { AvailableRow(device: $0) }
                ScanRow(none: available.isEmpty, first: paired.isEmpty)
                SectionLabel("Settings")
                SettingRow(icon: "gearshape", title: "Settings", text: "Name, sync switches, notifications, and agents") {
                    model.computersPath.append(.settings)
                }
                themeTile
                SettingRow(icon: "power", title: "Turn off Flux",
                           text: "This iPhone stops all connections until you turn Flux on again.", chevron: false) {
                    turningOff = true
                }
                .disabled(model.demo || !model.state.enabled)
            }
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.bottom, 24)
            .frame(maxWidth: TiledMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .refreshable { model.core.search() }
        .tabRoot("Computers")
        .confirmationDialog(
            unpairing.map { "Unpair \($0.name)?" } ?? "",
            isPresented: Binding(get: { unpairing != nil }, set: { if !$0 { unpairing = nil } }),
            titleVisibility: .visible,
            presenting: unpairing
        ) { device in
            Button("Unpair", role: .destructive) { model.unpair(device.id) }
        } message: { device in
            Text(model.unpairMessage(device))
        }
        .confirmationDialog("Turn off Flux?", isPresented: $turningOff, titleVisibility: .visible) {
            Button("Turn off", role: .destructive) { model.core.enabled = false }
        } message: {
            Text("This iPhone stops all connections to the computers. Approvals, agent alerts, and the clipboard do not reach this iPhone until you turn Flux on again.")
        }
    }

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    /// This iPhone: its name, and that computers can see it.
    private var phoneRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone")
                .font(.title3)
                .foregroundStyle(tn.cyan)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.state.deviceName.isEmpty ? "This iPhone" : model.state.deviceName)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(tn.text)
                Text(model.state.enabled ? "Visible to computers on this network" : "Not visible while Flux is off")
                    .font(.footnote)
                    .foregroundStyle(tn.sub)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .padding(.top, 4)
        .accessibilityElement(children: .combine)
    }

    /// The theme of the app: 4 choices. The Computer choice names the theme
    /// that it draws now and the computer that sent it.
    private var themeTile: some View {
        let theme = model.computerTheme
        let line = ThemeMode.computerLine(theme: theme,
                                          themeComputer: theme.flatMap { model.device($0.deviceId)?.name },
                                          scopeComputer: model.scope.flatMap { model.device($0)?.name },
                                          systemDark: scheme == .dark)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Theme")
                .font(.callout.weight(.semibold))
                .foregroundStyle(tn.text)
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, 4)
                .accessibilityAddTraits(.isHeader)
            ForEach(ThemeMode.allCases) { mode in
                ThemeChoiceRow(mode: mode, line: mode == .computer ? line : nil, selected: model.themeMode == mode) {
                    model.themeMode = mode
                }
            }
        }
        .padding(.bottom, 6)
        .background(tileShape().fill(tn.tile))
        .overlay(tileShape().strokeBorder(tn.line, lineWidth: 1))
    }
}

/// 1 choice of the theme: an icon, the label, the line of the Computer
/// choice, and the selection mark. The row takes the tap and gives the
/// state to VoiceOver.
private struct ThemeChoiceRow: View {
    let mode: ThemeMode
    let line: String?
    let selected: Bool
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: Self.icon(mode))
                    .font(.body)
                    .foregroundStyle(selected ? tn.accent : tn.sub)
                    .frame(minWidth: 24)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(mode.label)
                        .font(.subheadline.weight(selected ? .semibold : .regular))
                        .foregroundStyle(tn.text)
                    if let line {
                        Text(line)
                            .font(.footnote)
                            .foregroundStyle(tn.sub)
                    }
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(selected ? tn.accent : tn.dim)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .frame(minHeight: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private static func icon(_ mode: ThemeMode) -> String {
        switch mode {
        case .computer: return "laptopcomputer"
        case .system: return "iphone"
        case .light: return "sun.max"
        case .dark: return "moon"
        }
    }
}

/// A paired computer: its link, its battery, and its address. A tap makes
/// it the scope, or shows all computers when it is in scope. The chevron
/// opens the page of the computer.
struct PairedComputerRow: View {
    let device: DeviceSnapshot
    let inScope: Bool
    let onScope: () -> Void
    let onUnpair: () -> Void
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 24

    var body: some View {
        let d = device
        let battery = model.core.plugin(BatteryPlugin.self)?.model.computers[d.id]
        HStack(spacing: 0) {
            Button(action: onScope) {
                HStack(spacing: 12) {
                    Image(systemName: d.symbol)
                        .font(.system(size: iconSize))
                        .foregroundStyle(d.online ? tn.accent : tn.sub)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(d.name)
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(tn.text)
                        HStack(spacing: 6) {
                            LinkDot(online: d.online, size: 7)
                            if d.online, let battery {
                                BatteryDot(battery, size: 7)
                            }
                            Text(d.linkText(battery: battery))
                                .font(.footnote)
                                .foregroundStyle(tn.sub)
                                .lineLimit(2)
                        }
                        if !d.ip.isEmpty {
                            Text(d.ip)
                                .font(.caption.monospaced())
                                .foregroundStyle(tn.sub)
                                .lineLimit(1)
                        }
                        if !d.online {
                            Text("Check that Flux runs on \(d.name), and that both are on the same Wi-Fi.")
                                .font(.footnote)
                                .foregroundStyle(tn.sub)
                        }
                        if inScope {
                            Text("In scope")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(tn.accent)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 14)
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityHint(inScope ? "Shows all computers" : "Shows only \(d.name)")
            .accessibilityAddTraits(inScope ? .isSelected : [])
            Button(action: onUnpair) {
                Image(systemName: "minus.circle")
                    .foregroundStyle(tn.sub)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Unpair \(d.name)")
            Button { model.computersPath.append(.computer(d.id)) } label: {
                Image(systemName: "chevron.right")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(tn.sub)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(d.name)")
            .accessibilityHint("Shows the approval setup and the address of \(d.name)")
        }
        .padding(.trailing, 4)
        .frame(minHeight: 72)
        .background(tileShape().fill(tn.tile))
        .overlay(tileShape().strokeBorder(inScope ? tn.accent : tn.line, lineWidth: inScope ? 2 : 1))
    }
}

/// A computer that runs Flux and is not paired. A tap opens the pairing
/// sheet. The pairing guide of the Inbox uses it too.
struct AvailableRow: View {
    let device: DeviceSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = tileShape()
        Button { model.pairingSheet = device.id } label: {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.title3)
                    .foregroundStyle(tn.yellow)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(tn.text)
                    Text(device.pairState == .none ? "Tap to pair" : device.statusText)
                        .font(.footnote)
                        .foregroundStyle(tn.yellow)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(minHeight: 64)
            .overlay(shape.strokeBorder(tn.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Shows the key to pair with \(device.name)")
    }
}

/// The search state, help when no computer shows, and Scan again. `hint`
/// is the help under "No computers found", or nil for no help.
struct ScanRow: View {
    let none: Bool
    let first: Bool
    var hint: String? = "Open Flux on the computer, and use the same Wi-Fi network as this iPhone."
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.state.searching {
                HStack(spacing: 10) {
                    FluxSpinner(size: 16, color: tn.yellow)
                    Text("Looking for computers")
                        .font(.subheadline)
                        .foregroundStyle(tn.sub)
                }
                .frame(minHeight: 44)
            } else {
                if none {
                    Text(first ? "No computers found" : "No other computers found")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tn.text)
                    if let hint {
                        Text(hint)
                            .font(.footnote)
                            .foregroundStyle(tn.sub)
                    }
                }
                Button { model.core.search() } label: {
                    Label("Scan again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(FluxButtonStyle(kind: .text))
                .padding(.leading, -12)
                .disabled(!model.state.enabled)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row that opens a screen, with a chevron, or that runs an action, without one.
struct SettingRow: View {
    let icon: String
    let title: String
    let text: String
    var chevron = true
    let action: () -> Void
    @Environment(\.tn) private var tn
    @Environment(\.isEnabled) private var enabled
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 22

    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.system(size: iconSize))
                    .foregroundStyle(enabled ? tn.accent : tn.sub)
                    .frame(minWidth: iconSize + 4)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tn.text)
                    Text(text)
                        .font(.footnote)
                        .foregroundStyle(tn.sub)
                }
                .multilineTextAlignment(.leading)
                .frame(maxWidth: .infinity, alignment: .leading)
                if chevron {
                    Image(systemName: "chevron.right")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(tn.sub)
                        .accessibilityHidden(true)
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        }
        .buttonStyle(TiledPressStyle(fill: tn.tile, border: tn.line))
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
    }
}

/// A state of the app that limits Computers, such as Flux is off, with its next step.
private struct StateTile<Actions: View>: View {
    let icon: String
    let title: String
    let text: String
    @ViewBuilder let actions: Actions
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: icon)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tn.text)
                .accessibilityAddTraits(.isHeader)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(tn.sub)
            actions
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .tiledTile(fill: tn.tile, border: tn.line)
    }
}
