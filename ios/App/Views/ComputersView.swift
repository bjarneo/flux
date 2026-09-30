import FluxKit
import SwiftUI
import UIKit

/// The paired and available Omarchy computers.
struct ComputersView: View {
    @Environment(AppModel.self) private var model
    @State private var unpairing: DeviceSnapshot?

    var body: some View {
        Group {
            if !model.state.enabled {
                ContentUnavailableView {
                    Label("Flux is off", systemImage: "power")
                } description: {
                    Text("Flux uses no network while it is off, and computers do not see this iPhone.")
                } actions: {
                    Button("Turn on") { model.core.enabled = true }
                        .buttonStyle(.borderedProminent)
                }
            } else if model.state.localNetworkDenied && model.state.devices.isEmpty {
                ContentUnavailableView {
                    Label("Local Network is off", systemImage: "wifi.exclamationmark")
                } description: {
                    Text(Self.localNetworkText)
                } actions: {
                    Button("Open Settings", action: openSettings)
                        .buttonStyle(.borderedProminent)
                }
            } else if model.state.devices.isEmpty {
                ContentUnavailableView {
                    Label(model.state.searching ? "Searching…" : "No computer found", systemImage: "desktopcomputer")
                } description: {
                    Text("Start fluxd on an Omarchy computer on the same Wi-Fi.")
                } actions: {
                    if model.state.searching {
                        ProgressView()
                    } else {
                        Button("Search again") { model.core.search() }
                            .buttonStyle(.bordered)
                    }
                }
            } else {
                list
            }
        }
        .navigationTitle("Computers")
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                NavigationLink(value: Route.settings) {
                    Label("Settings", systemImage: "gearshape")
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button { model.core.search() } label: {
                    Label("Search again", systemImage: "arrow.clockwise")
                }
                .disabled(model.state.searching || !model.state.enabled)
            }
        }
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
    }

    private static let localNetworkText = "Flux needs Local Network access to find and reach computers. Turn on Local Network for Flux in Settings."

    private func openSettings() {
        if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
    }

    private var list: some View {
        List {
            // The paired computers stay in reach, for example to unpair one.
            if model.state.localNetworkDenied && !model.state.devices.contains(where: \.online) {
                Section {
                    Label("Local Network is off", systemImage: "wifi.exclamationmark")
                        .font(.body.weight(.medium))
                    Text(Self.localNetworkText)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Button("Open Settings", action: openSettings)
                }
            }
            if !model.paired.isEmpty {
                Section("Paired") {
                    ForEach(model.paired) { device in
                        NavigationLink(value: Route.device(device.id)) {
                            DeviceRow(device: device)
                        }
                        .swipeActions {
                            Button("Unpair", role: .destructive) { unpairing = device }
                        }
                    }
                }
            }
            Section {
                ForEach(model.available) { device in
                    Button { model.pairingSheet = device.id } label: {
                        DeviceRow(device: device, action: "Pair")
                    }
                    .tint(.primary)
                    .accessibilityHint("Shows the key to pair with \(device.name)")
                }
                if model.state.searching {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("Searching…").foregroundStyle(.secondary)
                    }
                } else if model.available.isEmpty {
                    Text(model.paired.isEmpty ? "No computer found" : "No other computer found")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Available")
            } footer: {
                Text("Flux shows the Omarchy computers that run fluxd on this network. You can also pair from the computer with flux-cli pair.")
            }
        }
        .listStyle(.insetGrouped)
    }
}

/// A computer in the list: its icon, name, and state.
struct DeviceRow: View {
    let device: DeviceSnapshot
    var action: String?

    var body: some View {
        HStack(spacing: 12) {
            FeatureIcon(systemImage: device.symbol, tint: device.online ? .accentColor : .secondary, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.body.weight(.medium))
                HStack(spacing: 6) {
                    Circle()
                        .fill(device.online ? Color.green : Color.secondary.opacity(0.5))
                        .frame(width: 7, height: 7)
                        .accessibilityHidden(true)
                    Text(device.statusText)
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            if let action, device.online, device.pairState == .none {
                Text(action)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}
