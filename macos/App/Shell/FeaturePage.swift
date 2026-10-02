import FluxKit
import SwiftUI

/// The page of 1 feature card for a computer, from Send, Control, or the
/// Inbox. The card keeps its own layout and colors.
struct FeaturePage: View {
    @Environment(AppModel.self) private var model
    let card: MacCard
    let deviceId: String

    var body: some View {
        Group {
            if let device = model.pairedDevice(deviceId) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        section(device)
                    }
                    .padding(20)
                    .frame(maxWidth: TiledMetrics.maxContentWidth)
                    .frame(maxWidth: .infinity)
                }
                .navigationSubtitle(device.name)
            } else {
                ContentUnavailableView("The computer is gone", systemImage: "desktopcomputer",
                                       description: Text("The computer is no longer paired."))
            }
        }
        .navigationTitle(card.title)
    }

    @ViewBuilder
    private func section(_ device: DeviceSnapshot) -> some View {
        switch card {
        case .share: ShareSection(device: device)
        case .clipboard: ClipboardSection(device: device)
        case .media: MediaSection(device: device)
        case .commands: CommandsSection(device: device)
        case .mic: MicSection(device: device)
        case .stream: StreamSection(device: device)
        }
    }
}
