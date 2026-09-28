import FluxKit
import SwiftUI

/// The screen of a paired computer: its state, the quick actions, and one
/// tile per feature, like the home screen of the Android app.
struct DeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let deviceId: String
    @State private var confirmUnpair = false

    var body: some View {
        Group {
            if let device = model.device(deviceId), device.paired {
                content(device)
            } else {
                ContentUnavailableView("Not paired", systemImage: "link", description: Text("Pair with the computer again from the list."))
            }
        }
        .background(Color(.systemGroupedBackground))
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: model.device(deviceId)?.paired != true) { _, gone in
            if gone { dismiss() }
        }
    }

    private func content(_ device: DeviceSnapshot) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                DeviceHeader(device: device)
                FeatureBanners(device: device)
                QuickActions(device: device)
                FeatureGrid {
                    FeatureTiles(device: device)
                }
            }
            .padding(16)
            .frame(maxWidth: 900)
            .frame(maxWidth: .infinity)
        }
        .navigationTitle(device.name)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    Button("Unpair \(device.name)", systemImage: "link.badge.minus", role: .destructive) { confirmUnpair = true }
                } label: {
                    Label("More", systemImage: "ellipsis.circle")
                }
            }
        }
        .confirmationDialog("Unpair \(device.name)?", isPresented: $confirmUnpair, titleVisibility: .visible) {
            Button("Unpair", role: .destructive) { model.core.unpair(device.id) }
        } message: {
            Text("\(device.name) and this iPhone forget each other. Pair again to use it.")
        }
    }
}

/// The name, connection, address, and feature states of a computer.
struct DeviceHeader: View {
    @Environment(AppModel.self) private var model
    let device: DeviceSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                Image(systemName: device.symbol)
                    .font(.system(size: 26))
                    .foregroundStyle(.white)
                    .frame(width: 56, height: 56)
                    .background(
                        RoundedRectangle(cornerRadius: 14, style: .continuous)
                            .fill(LinearGradient(colors: [.accentColor, .accentColor.opacity(0.65)], startPoint: .topLeading, endPoint: .bottomTrailing))
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text(device.name)
                        .font(.title2.weight(.semibold))
                        .lineLimit(2)
                    StatusPill(text: device.online ? "Connected" : "Not reachable", color: device.online ? .green : .secondary)
                }
                Spacer(minLength: 0)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 14) { details }
                VStack(alignment: .leading, spacing: 6) { details }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            if !device.online {
                HStack(alignment: .firstTextBaseline) {
                    Text("Check that Flux runs on \(device.name), and that both are on the same Wi-Fi.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    Button("Retry") { model.core.search() }
                        .font(.subheadline.weight(.semibold))
                        .disabled(model.state.searching)
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardBackground()
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var details: some View {
        if !device.ip.isEmpty {
            Label(device.ip, systemImage: "network")
        }
        if device.online {
            FeatureBadges(device: device)
        }
    }
}

/// The actions that a tap runs at once, side by side in one bar under the
/// header, like the action row of the Android app.
struct QuickActions: View {
    let device: DeviceSnapshot

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            FeatureQuickActions(device: device)
        }
        .padding(.vertical, 14)
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity)
        .cardBackground()
        .disabled(!device.online)
    }
}
