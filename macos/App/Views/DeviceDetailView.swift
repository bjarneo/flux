import FluxKit
import SwiftUI

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
                Text("Accept only when \(device.name) shows the same key. Compare all 16 characters.")
                    .foregroundStyle(.secondary)
                // Accept is not the default button, so that Return cannot
                // accept a request that came while the user typed.
                HStack {
                    Button("Reject", role: .cancel) { model.core.cancelPair(device.id) }
                    Button("Accept") { model.core.acceptPair(device.id) }
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

/// The key that both sides show while they pair, in groups of 4 digits.
struct KeyView: View {
    let key: String

    var body: some View {
        Text(key.isEmpty ? "---- ---- ---- ----" : Self.grouped(key))
            .font(.system(size: 26, weight: .semibold, design: .monospaced))
            .kerning(2)
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .textSelection(.enabled)
            .padding(.horizontal, 20)
            .padding(.vertical, 10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
    }

    /// The key in groups of 4 digits, for example "5EE6 825F 974E D59A".
    nonisolated static func grouped(_ key: String) -> String {
        stride(from: 0, to: key.count, by: 4).map { start in
            String(key.dropFirst(start).prefix(4))
        }
        .joined(separator: " ")
    }
}
