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
            Circle()
                .fill(device.online ? Color.green : Color.secondary.opacity(0.4))
                .frame(width: 8, height: 8)
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
