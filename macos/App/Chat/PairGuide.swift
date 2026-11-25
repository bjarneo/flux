import AppKit
import FluxKit
import SwiftUI

/// The detail column of Chats before the first pairing: the pairing guide
/// in a large tile with the active border.
struct ChatPairGuide: View {
    @Environment(\.tn) private var tn

    var body: some View {
        PairGuide()
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous).fill(tn.tile))
            .activeBorder(tn)
    }
}

/// The title of the large tile.
private struct Heading: View {
    let text: String
    @Environment(\.tn) private var tn

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 20, weight: .semibold))
            .foregroundStyle(tn.text)
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityAddTraits(.isHeader)
    }
}

/// A paragraph of the large tile.
private struct Paragraph: View {
    let text: String
    @Environment(\.tn) private var tn

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        Text(text)
            .font(.system(size: 13))
            .foregroundStyle(tn.sub)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// The guide before the first pairing: what Flux is, how to set up Flux
/// on the Omarchy computer, and the computers to pair. When this Mac found
/// a computer, the pair step comes first. When macOS blocks the local
/// network for Flux, the Local Network notice comes before the steps.
private struct PairGuide: View {
    static let installGuide = URL(string: "https://github.com/bjarneo/flux/blob/master/docs/install.md")!
    static let setupCommand = "flux-cli setup"
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let available = model.available.filter(\.online)
        let localNetworkOff = model.state.localNetworkDenied && !model.state.devices.contains(where: \.online)
        VStack(alignment: .leading, spacing: 10) {
            Heading("Pair your Omarchy computer")
            Paragraph("Flux lets this Mac answer agents, approve sudo, and send files to your Omarchy computer.")
            if localNetworkOff {
                LocalNetworkNotice()
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .tiledTile(fill: tn.tile, border: tn.yellow, padding: 0)
                    .padding(.top, 6)
            }
            if available.isEmpty {
                GuideStep("1. Set up Flux on the computer") {
                    Paragraph("Install the Flux package on the computer. Then start fluxd for your desktop user:")
                    CommandBlock(Self.setupCommand)
                    installButton
                }
                GuideStep("2. Pair this Mac") {
                    pairStep(available)
                }
            } else {
                GuideStep("Pair this Mac") {
                    pairStep(available)
                }
                GuideStep("Another computer") {
                    Paragraph("To add a computer, run \(Self.setupCommand) on it.")
                    installButton
                }
            }
        }
    }

    private var installButton: some View {
        Button {
            NSWorkspace.shared.open(Self.installGuide)
        } label: {
            Label("Read the install guide", systemImage: "arrow.up.right.square")
        }
        .buttonStyle(FluxButtonStyle(kind: .text))
        .padding(.leading, -8)
    }

    @ViewBuilder
    private func pairStep(_ available: [DeviceSnapshot]) -> some View {
        Paragraph("Select the computer. Then compare the key on both screens.")
        ForEach(available) { d in
            AvailableRow(device: d) { model.push(.pairing(d.id)) }
        }
        ScanRow(first: true, noneFound: available.isEmpty,
                hint: "Check that you ran \(Self.setupCommand) on the computer, and that both are on the same network.")
    }
}

/// 1 step of the pairing guide: a heading, then its content.
private struct GuideStep<Content: View>: View {
    let title: String
    let content: Content
    @Environment(\.tn) private var tn

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(tn.text)
                .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(.top, 6)
    }
}
