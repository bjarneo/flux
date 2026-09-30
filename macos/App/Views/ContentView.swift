import AppKit
import FluxKit
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            DeviceListView()
                .navigationSplitViewColumnWidth(min: 220, ideal: 240)
        } detail: {
            if let device = model.device {
                DeviceDetailView(device: device)
                    .id(device.id)
            } else if model.state.localNetworkDenied && !model.state.devices.contains(where: \.online) {
                // A link that is open shows that Flux reaches a computer.
                ContentUnavailableView {
                    Label("Local Network is off", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(LocalNetworkNotice.text)
                } actions: {
                    Button("Open System Settings") { NSWorkspace.shared.open(LocalNetworkNotice.settings) }
                }
            } else {
                ContentUnavailableView {
                    Label("No computer found", systemImage: "desktopcomputer")
                } description: {
                    Text(model.state.searching ? "Searching…" : "Start fluxd on an Omarchy computer on the same network.")
                } actions: {
                    Button("Search again") { model.core.search() }
                        .disabled(model.state.searching)
                }
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.bottom, 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.default, value: model.toast)
        .sheet(item: Binding(
            get: { model.pairingSheet.flatMap { id in model.state.devices.first { $0.id == id } } },
            set: { model.pairingSheet = $0?.id }
        )) { device in
            PairRequestSheet(device: device)
        }
    }
}

struct DeviceListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: $model.selection) {
            // The paired computers stay in reach, for example to unpair one.
            if model.state.localNetworkDenied && !model.state.devices.contains(where: \.online) {
                Section {
                    LocalNetworkNotice()
                }
            }
            if !model.paired.isEmpty {
                Section("Paired") {
                    ForEach(model.paired) { DeviceRow(device: $0).tag($0.id) }
                }
            }
            Section("Available") {
                if model.state.searching {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Searching…")
                    }
                    .foregroundStyle(.secondary)
                } else if model.available.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.paired.isEmpty ? "No computer found" : "No other computer found")
                            .foregroundStyle(.secondary)
                        Button("Search again") { model.core.search() }
                    }
                }
                ForEach(model.available) { DeviceRow(device: $0).tag($0.id) }
            }
        }
        .toolbar {
            ToolbarItem {
                Button { model.core.search() } label: { Label("Search again", systemImage: "arrow.clockwise") }
                    .help("Search the network for Omarchy computers")
                    .disabled(model.state.searching)
            }
        }
        .safeAreaInset(edge: .bottom) {
            HStack {
                Image(systemName: FluxCore.deviceType == "laptop" ? "laptopcomputer" : "desktopcomputer")
                Text(model.state.deviceName).lineLimit(1)
                Spacer()
                if !model.state.enabled { Text("Off").foregroundStyle(.secondary) }
            }
            .font(.caption)
            .padding(10)
        }
    }
}

/// Tells the user that macOS blocks the local network for Flux, and where
/// to allow it. Discovery and links fail without it.
struct LocalNetworkNotice: View {
    static let text = "Flux needs Local Network access to find and reach computers. Turn on Flux in System Settings > Privacy & Security > Local Network."
    static let settings = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Local Network is off", systemImage: "wifi.exclamationmark")
                .font(.body.weight(.medium))
            Text(Self.text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Open System Settings") { NSWorkspace.shared.open(Self.settings) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.vertical, 4)
    }
}

struct DeviceRow: View {
    let device: DeviceSnapshot

    var body: some View {
        HStack {
            Image(systemName: device.symbol)
                .frame(width: 22)
            VStack(alignment: .leading) {
                Text(device.name)
                Text(device.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            // A request from the computer waits here, so that it does not take the window.
            if device.pairState == .incoming {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                    .help("\(device.name) wants to pair")
            } else {
                Circle()
                    .fill(device.online ? Color.green : Color.secondary.opacity(0.4))
                    .frame(width: 8, height: 8)
            }
        }
    }
}

extension DeviceSnapshot {
    var symbol: String {
        switch type {
        case "laptop": return "laptopcomputer"
        case "desktop": return "desktopcomputer"
        case "tablet": return "ipad"
        case "tv": return "tv"
        default: return "iphone"
        }
    }

    var statusText: String {
        switch pairState {
        case .requested: return "Waiting for the computer"
        case .incoming: return "Wants to pair"
        case .paired: return online ? "Connected" : "Offline"
        case .none: return online ? "Not paired" : "Offline"
        }
    }
}
