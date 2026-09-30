import FluxKit
import SwiftUI

/// Pairs with one computer in both directions: it shows the key before this
/// iPhone sends a request, while the computer confirms, and when the
/// computer asks.
struct PairSheet: View {
    @Environment(AppModel.self) private var model
    let deviceId: String
    @State private var timestamp = Int64(Date().timeIntervalSince1970)

    var body: some View {
        NavigationStack {
            Group {
                if let device = model.device(deviceId) {
                    content(device)
                } else {
                    ContentUnavailableView("The computer left the network", systemImage: "wifi.slash")
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                if model.device(deviceId)?.pairState == PairState.none {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { model.pairingSheet = nil }
                    }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(isRequested)
        .onAppear { model.shownPairSheet = deviceId }
    }

    /// A request that this iPhone sent ends with Cancel, not a swipe. A
    /// swipe on a request from a computer rejects it, see
    /// `AppModel.pairSheetClosed`.
    private var isRequested: Bool {
        model.device(deviceId)?.pairState == .requested
    }

    @ViewBuilder
    private func content(_ device: DeviceSnapshot) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                FeatureIcon(systemImage: device.symbol, tint: .accentColor, size: 56)
                switch device.pairState {
                case .incoming:
                    title("\(device.name) wants to pair")
                    KeyView(key: device.pairKey)
                    explanation("Accept only when \(device.name) shows the same key. Compare all 16 characters.")
                    HStack(spacing: 12) {
                        Button(role: .destructive) { model.rejectPair(device) } label: {
                            Text("Reject").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.bordered)
                        Button { model.core.acceptPair(device.id) } label: {
                            Text("Accept").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                    .controlSize(.large)
                case .requested:
                    title("Confirm on \(device.name)")
                    KeyView(key: device.pairKey)
                    explanation("Accept the request on the computer when it shows the same key.")
                    ProgressView()
                    Button("Cancel request", role: .cancel) { model.core.cancelPair(device.id) }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                case .none:
                    title("Pair with \(device.name)")
                    KeyView(key: model.core.previewKey(device.id, timestamp: timestamp))
                    explanation("The computer shows the same key. Accept the request there when the keys match.")
                    Button {
                        model.core.pair(device.id, timestamp: timestamp)
                    } label: {
                        Text("Send request").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!device.online)
                case .paired:
                    title("Paired with \(device.name)")
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                        .accessibilityHidden(true)
                }
            }
            .frame(maxWidth: 420)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
    }

    private func title(_ text: String) -> some View {
        Text(text)
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
    }

    private func explanation(_ text: String) -> some View {
        Text(text)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
    }
}
