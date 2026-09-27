import FluxKit
import SwiftUI

struct DeviceDetailView: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        Group {
            if device.paired {
                PairedDeviceView(device: device)
            } else {
                PairingView(device: device)
            }
        }
        .navigationTitle(device.name)
        .navigationSubtitle(device.paired ? "" : device.ip.isEmpty ? device.statusText : "\(device.statusText) · \(device.ip)")
        .toolbar {
            if device.paired {
                ToolbarItem {
                    Menu {
                        Button("Unpair \(device.name)", role: .destructive) { model.core.unpair(device.id) }
                    } label: { Label("More", systemImage: "ellipsis.circle") }
                }
            }
        }
    }
}

/// The dashboard of a paired computer: a header with its state and quick
/// actions, banners for things that need attention, and the feature cards.
struct PairedDeviceView: View {
    let device: DeviceSnapshot

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DeviceHeader(device: device)
                if !device.online {
                    Banner("\(device.name) is offline. Flux connects when it is on the same network.", systemImage: "wifi.slash", tint: .secondary) {}
                }
                FeatureBanners(device: device)
                CardGridLayout(minColumnWidth: 300, spacing: 16) {
                    FeatureSections(device: device)
                }
            }
            .padding(20)
            .frame(maxWidth: 1500)
            .frame(maxWidth: .infinity)
        }
    }
}

/// The name, state, and quick actions of a paired computer.
struct DeviceHeader: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 16) {
                Image(systemName: device.symbol)
                    .font(.system(size: 28))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 60)
                    .background(
                        RoundedRectangle(cornerRadius: 15, style: .continuous)
                            .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name).font(.title2.weight(.semibold))
                    HStack(spacing: 12) {
                        StatusPill(text: device.online ? "Connected" : "Offline", color: device.online ? .green : .secondary)
                        if !device.ip.isEmpty {
                            Label(device.ip, systemImage: "network")
                        }
                        FeatureBadges(device: device)
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                }
                Spacer()
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 96), spacing: 10)], spacing: 10) {
                FeatureQuickActions(device: device)
                Tile(title: "Ping", systemImage: "bell") { model.core.plugin(PingPlugin.self)?.ping(device.id) }
                    .help("Send a ping to \(device.name)")
            }
            .disabled(!device.online)
        }
        .padding(20)
        .cardBackground()
    }
}

/// Pairing states of a computer that is not paired.
struct PairingView: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: device.symbol)
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(.secondary)
            switch device.pairState {
            case .incoming:
                Text("\(device.name) wants to pair").font(.title2)
                KeyView(key: device.pairKey)
                Text("Accept only when \(device.name) shows the same key.")
                    .foregroundStyle(.secondary)
                HStack {
                    Button("Reject", role: .cancel) { model.core.cancelPair(device.id) }
                    Button("Accept") { model.core.acceptPair(device.id) }
                        .keyboardShortcut(.defaultAction)
                }
            case .requested:
                Text("Confirm on \(device.name)").font(.title2)
                KeyView(key: device.pairKey)
                Text("Accept the request on the computer when it shows the same key.")
                    .foregroundStyle(.secondary)
                ProgressView().controlSize(.small)
                Button("Cancel", role: .cancel) { model.core.cancelPair(device.id) }
            case .none, .paired:
                Text(device.name).font(.title2)
                if device.online {
                    Text("Pair this Mac to share files, the clipboard, media controls, and more.")
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    Button("Pair…") { model.pairingSheet = device.id }
                        .keyboardShortcut(.defaultAction)
                } else {
                    Text("Offline").foregroundStyle(.secondary)
                }
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Shows the key before this Mac sends a pairing request.
struct PairRequestSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let device: DeviceSnapshot
    @State private var timestamp = Int64(Date().timeIntervalSince1970)

    var body: some View {
        VStack(spacing: 16) {
            Text("Pair with \(device.name)").font(.title2)
            KeyView(key: model.core.previewKey(device.id, timestamp: timestamp))
            Text("The computer shows the same key. Accept the request there when the keys match.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 340)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }
                Button("Send request") {
                    model.core.pair(device.id, timestamp: timestamp)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(28)
    }
}

struct KeyView: View {
    let key: String

    var body: some View {
        Text(key.isEmpty ? "--------" : key)
            .font(.system(size: 34, weight: .semibold, design: .monospaced))
            .kerning(4)
            .textSelection(.enabled)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }
}
