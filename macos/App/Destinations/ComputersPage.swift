import AppKit
import FluxKit
import SwiftUI

/// Computers: this Mac, the paired computers, and the computers to pair. A
/// click on a paired computer sets the scope. Its page holds the Touch ID
/// approval and Unpair. The theme is in the Settings window.
struct ComputersPage: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let localNetworkOff = model.state.localNetworkDenied && !model.state.devices.contains(where: \.online)
        ScrollView {
            VStack(alignment: .leading, spacing: TiledMetrics.gap) {
                ThisMacRow()
                if localNetworkOff {
                    LocalNetworkNotice()
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .tiledTile(fill: tn.tile, border: tn.yellow, padding: 0)
                }
                SectionLabel("Paired")
                if model.paired.isEmpty {
                    Text("No computer is paired. Pair one below. A paired computer connects by itself.")
                        .font(.system(size: 13))
                        .foregroundStyle(tn.sub)
                        .padding(.horizontal, 4)
                }
                ForEach(model.paired) { d in
                    ComputerRow(device: d)
                }
                SectionLabel("Available")
                ForEach(model.available) { d in
                    AvailableRow(device: d) { model.push(.pairing(d.id)) }
                }
                ScanRow(first: model.paired.isEmpty, noneFound: model.available.isEmpty,
                        hint: "Open Flux on the computer, and use the same network as this Mac.")
                SectionLabel("Settings")
                SettingsLink {
                    ToolRowLabel(icon: "gearshape", title: "Settings", line: "Theme, sync, notifications, and agents")
                }
                .buttonStyle(TilePressStyle())
            }
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: TiledMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .destinationRoot(.computers)
    }
}

/// This Mac: its name, and whether computers can reach it.
private struct ThisMacRow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: FluxCore.deviceType == "laptop" ? "laptopcomputer" : "desktopcomputer")
                .font(.system(size: 20))
                .foregroundStyle(tn.cyan)
                .frame(width: 28)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.state.deviceName)
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(tn.text)
                Text(model.state.enabled ? "Visible to computers on this network" : "Flux is off. Computers cannot reach this Mac.")
                    .font(.system(size: 12))
                    .foregroundStyle(model.state.enabled ? tn.sub : tn.yellow)
            }
            Spacer(minLength: 8)
            if !model.state.enabled {
                Button("Turn on Flux") { model.core.enabled = true }
                    .buttonStyle(FluxButtonStyle(kind: .outlined))
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
        .tiledTile(fill: tn.tile, border: tn.line, padding: 0)
    }
}

/// A paired computer. A click sets the scope to it, or back to all
/// computers when it is in scope. The border is 2 pt `accent` in scope.
struct ComputerRow: View {
    let device: DeviceSnapshot
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var confirmUnpair = false

    var body: some View {
        let inScope = model.scope == device.id
        let battery = model.core.plugin(BatteryPlugin.self)?.model.computers[device.id]
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
        HStack(spacing: 4) {
            Button {
                model.setScope(inScope ? nil : device.id)
            } label: {
                HStack(spacing: 12) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 20))
                        .foregroundStyle(device.online ? tn.accent : tn.sub)
                        .frame(width: 28)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name)
                            .font(.system(size: 15, weight: .semibold))
                            .foregroundStyle(tn.text)
                        HStack(spacing: 6) {
                            LinkDot(online: device.online, size: 7)
                            Text(linkText(device, battery: battery))
                                .font(.system(size: 12))
                                .foregroundStyle(tn.sub)
                        }
                        if !device.ip.isEmpty {
                            Text(device.ip)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(tn.sub)
                        }
                        if !device.online {
                            Text("Check that Flux runs on \(device.name), and that both are on the same network.")
                                .font(.system(size: 12))
                                .foregroundStyle(tn.sub)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        if inScope {
                            Text("In scope")
                                .font(.system(size: 11, weight: .medium))
                                .foregroundStyle(tn.accent)
                        }
                    }
                    .multilineTextAlignment(.leading)
                    Spacer(minLength: 8)
                }
                .padding(.leading, 14)
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(TilePressStyle())
            .accessibilityLabel("\(device.name), \(linkText(device, battery: battery))")
            .accessibilityValue(inScope ? "In scope" : "")
            .accessibilityHint(inScope ? "Shows all computers" : "Shows only \(device.name)")
            if !device.online {
                Button("Retry") { model.retry() }
                    .buttonStyle(FluxButtonStyle(kind: .text))
            }
            Button { model.push(.computer(device.id)) } label: {
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tn.sub)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TilePressStyle())
            .help("Open the page of \(device.name)")
            .accessibilityLabel("Open the page of \(device.name)")
            Button { confirmUnpair = true } label: {
                Image(systemName: "minus.circle")
                    .font(.system(size: 14))
                    .foregroundStyle(tn.sub)
                    .frame(width: 32, height: 32)
                    .contentShape(Rectangle())
            }
            .buttonStyle(TilePressStyle())
            .help("Unpair \(device.name)")
            .accessibilityLabel("Unpair \(device.name)")
            .padding(.trailing, 8)
        }
        .background(shape.fill(tn.tile))
        .overlay(shape.strokeBorder(inScope ? tn.accent : tn.line, lineWidth: inScope ? 2 : 1))
        .contextMenu {
            Button(inScope ? "Show all computers" : "Show only \(device.name)") { model.setScope(inScope ? nil : device.id) }
            Button("Open the page of \(device.name)") { model.push(.computer(device.id)) }
            Divider()
            Button("Unpair \(device.name)…", role: .destructive) { confirmUnpair = true }
        }
        .confirmationDialog("Unpair \(device.name)?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { model.unpair(device.id) }
        } message: {
            Text(model.unpairMessage(device))
        }
    }
}

/// A computer to pair: a dashed `yellow` border. A click opens the pairing page.
struct AvailableRow: View {
    let device: DeviceSnapshot
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
        let incoming = device.pairState == .incoming
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: incoming ? "exclamationmark.circle" : "plus")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(tn.yellow)
                    .frame(width: 28)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(tn.text)
                    Text(line(incoming: incoming))
                        .font(.system(size: 12))
                        .foregroundStyle(tn.yellow)
                }
                Spacer(minLength: 8)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 52, alignment: .leading)
            .background(shape.fill(tn.bg))
            .overlay(shape.strokeBorder(tn.yellow, style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .accessibilityHint("Opens the pairing page")
    }

    private func line(incoming: Bool) -> String {
        if incoming { return "Wants to pair. Compare the key." }
        if device.pairState == .requested { return "Waiting for the computer" }
        return device.online ? "Select to pair" : "Offline"
    }
}

/// The search row: a spinner while Flux searches, else the result and Search again.
struct ScanRow: View {
    /// True when no computer is paired. The text then says "No computers found".
    let first: Bool
    /// True when Flux found no computer to pair.
    let noneFound: Bool
    let hint: String
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if model.state.searching {
                HStack(spacing: 10) {
                    FluxSpinner()
                    Text("Looking for computers")
                        .font(.system(size: 13))
                        .foregroundStyle(tn.sub)
                }
                .frame(minHeight: 32)
            } else {
                if noneFound {
                    Text(first ? "No computers found" : "No other computers found")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(tn.text)
                    Text(hint)
                        .font(.system(size: 12))
                        .foregroundStyle(tn.sub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button { model.retry() } label: {
                    Label("Search again", systemImage: "arrow.clockwise")
                }
                .buttonStyle(FluxButtonStyle(kind: .text))
                .padding(.leading, -8)
            }
        }
        .padding(.horizontal, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The page of a paired computer: its state, the scope, the Touch ID
/// approval, and Unpair.
struct ComputerPage: View {
    let deviceId: String
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var confirmUnpair = false

    var body: some View {
        Group {
            if let device = model.pairedDevice(deviceId) {
                content(device)
                    .navigationTitle(device.name)
                    .navigationSubtitle(linkText(device, battery: model.core.plugin(BatteryPlugin.self)?.model.computers[device.id]))
            } else {
                ContentUnavailableView("The computer is gone", systemImage: "desktopcomputer",
                                       description: Text("The computer is no longer paired."))
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(tn.bg)
    }

    private func content(_ device: DeviceSnapshot) -> some View {
        let inScope = model.scope == device.id
        return ScrollView {
            VStack(alignment: .leading, spacing: TiledMetrics.gap) {
                HStack(spacing: 12) {
                    Image(systemName: device.symbol)
                        .font(.system(size: 28))
                        .foregroundStyle(device.online ? tn.accent : tn.sub)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(device.name)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(tn.text)
                            .accessibilityAddTraits(.isHeader)
                        if !device.ip.isEmpty {
                            Text(device.ip)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(tn.sub)
                                .textSelection(.enabled)
                        }
                    }
                    Spacer(minLength: 8)
                    Button(inScope ? "Show all computers" : "Show only \(device.name)") {
                        model.setScope(inScope ? nil : device.id)
                    }
                    .buttonStyle(FluxButtonStyle(kind: .outlined))
                }
                .padding(14)
                .tiledTile(fill: tn.tile, border: inScope ? tn.accent : tn.line, padding: 0)
                SectionLabel("Approval")
                ApproveSection(device: device)
                SectionLabel("Pairing")
                Button("Unpair \(device.name)…") { confirmUnpair = true }
                    .buttonStyle(FluxButtonStyle(kind: .destructive))
                    .padding(.horizontal, 4)
            }
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.top, 8)
            .padding(.bottom, 24)
            .frame(maxWidth: TiledMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
        .confirmationDialog("Unpair \(device.name)?", isPresented: $confirmUnpair) {
            Button("Unpair", role: .destructive) { model.unpair(device.id) }
        } message: {
            Text(model.unpairMessage(device))
        }
    }
}
