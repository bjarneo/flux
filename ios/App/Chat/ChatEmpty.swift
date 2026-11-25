import FluxKit
import SwiftUI

/// Chats before it can show chats: "Flux is off" while Flux is off, and
/// the pairing guide before the first pairing. A large tile with the active
/// border holds it.
struct ChatEmpty: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        ScrollView {
            EmptyTile {
                if model.state.enabled { PairGuide() } else { off }
            }
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.top, 12)
            .padding(.bottom, 16)
            .frame(maxWidth: TiledMetrics.maxContentWidth)
            .frame(maxWidth: .infinity)
        }
    }

    private var off: some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "power")
                .font(.title2)
                .foregroundStyle(tn.yellow)
                .accessibilityHidden(true)
            EmptyTitle(text: "Flux is off")
            EmptyLine(text: "Flux uses no network while it is off, and computers do not see this iPhone.")
            Button("Turn on") { model.core.enabled = true }
                .buttonStyle(FluxButtonStyle(kind: .filled))
                .disabled(model.demo)
        }
    }
}

/// The large tile of Chats before it can show chats, with the active border.
private struct EmptyTile<Content: View>: View {
    @ViewBuilder let content: Content
    @Environment(\.tn) private var tn

    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .tiledTile(fill: tn.tile, border: .clear, padding: 20)
            .activeBorder(tn)
    }
}

/// The title of the large tile.
private struct EmptyTitle: View {
    let text: String
    @Environment(\.tn) private var tn

    var body: some View {
        Text(text)
            .font(.title2.weight(.semibold))
            .foregroundStyle(tn.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A line of the large tile.
private struct EmptyLine: View {
    let text: String
    @Environment(\.tn) private var tn

    var body: some View {
        Text(text)
            .font(.subheadline)
            .foregroundStyle(tn.sub)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Chats before the first pairing: what Flux does, how to set up Flux
/// on the computer, and the computers on the network with their pair
/// action. When this iPhone already found a computer, the pair step comes
/// first.
private struct PairGuide: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    private static let setup = "flux-cli setup"

    var body: some View {
        let available = model.state.devices.filter { !$0.paired && $0.online }
        VStack(alignment: .leading, spacing: 10) {
            EmptyTitle(text: "Pair your Omarchy computer")
            EmptyLine(text: "Flux lets this iPhone answer agents, approve sudo, and send files to your Omarchy computer.")
            if available.isEmpty {
                GuideStep(title: "1. Set up Flux on the computer") {
                    EmptyLine(text: "Install the Flux package on the computer. Then start fluxd for your desktop user:")
                    CommandBlock(Self.setup)
                }
                GuideStep(title: "2. Pair this iPhone") { pairStep(available) }
            } else {
                GuideStep(title: "Pair this iPhone") { pairStep(available) }
                GuideStep(title: "Another computer") {
                    EmptyLine(text: "To add a computer, run \(Self.setup) on it.")
                }
            }
        }
    }

    @ViewBuilder
    private func pairStep(_ available: [DeviceSnapshot]) -> some View {
        EmptyLine(text: "Tap the computer. Then compare the key on both screens.")
        ForEach(available) { AvailableRow(device: $0) }
        ScanRow(none: available.isEmpty, first: true,
                hint: "Check that you ran \(Self.setup) on the computer, and that both are on the same Wi-Fi.")
    }
}

/// 1 step of the pairing guide: a heading and its content.
private struct GuideStep<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content
    @Environment(\.tn) private var tn

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tn.text)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.top, 10)
    }
}
