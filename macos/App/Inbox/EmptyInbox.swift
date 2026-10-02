import Accessibility
import AppKit
import FluxKit
import SwiftUI

/// The Inbox with no item in scope: a large tile in the master position,
/// then the notices and 2 action tiles. The tile is the pairing guide
/// before the first pairing.
struct EmptyInbox: View {
    let status: InboxStatus
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The modes of the large tile, in the order of the checks.
    enum Mode: Hashable {
        case guide
        case connecting(String?)
        case offline(String?)
        case paired(String)
        case clear(String?)
    }

    var body: some View {
        let shown = mode
        VStack(spacing: TiledMetrics.gap) {
            tile(shown)
                .id(shown)
                .transition(.opacity)
                .animation(Motion.standard(reduceMotion), value: shown)
            if shown != .guide {
                InboxNotices(status: status, pairedTile: isPaired(shown), offlineInLine: isOffline(shown))
                ActionTiles()
            }
        }
    }

    private var mode: Mode {
        if model.paired.isEmpty { return .guide }
        let reach = Inbox.reach(scope: model.scope, devices: model.state.devices)
        // The name of the computer in scope, or of the only paired computer.
        let name = status.scopeName ?? (model.paired.count == 1 ? model.paired[0].name : nil)
        if reach.noneOnline && model.connecting { return .connecting(name) }
        if reach.noneOnline { return .offline(name) }
        if let paired = status.pairedName { return .paired(paired) }
        return .clear(status.scopeName)
    }

    private func isPaired(_ mode: Mode) -> Bool {
        if case .paired = mode { return true }
        return false
    }

    private func isOffline(_ mode: Mode) -> Bool {
        switch mode {
        case .connecting, .offline: return true
        case .guide, .paired, .clear: return false
        }
    }

    @ViewBuilder
    private func tile(_ mode: Mode) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            switch mode {
            case .guide:
                PairGuide()
            case .connecting(let name):
                FluxSpinner(size: 20)
                Heading(name.map { "Connecting to \($0)" } ?? "Connecting to your computers")
                Paragraph("What waits for you shows here when the connection is ready.")
            case .offline(let name):
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 24))
                    .foregroundStyle(tn.yellow)
                    .accessibilityHidden(true)
                Heading(name.map { "\($0) is not reachable" } ?? "No computer is reachable")
                Paragraph("Check that Flux runs on the computer, and that this Mac can reach it on this network or on Tailscale.")
                Paragraph("The Inbox shows what waits on a computer only while the computer is reachable.")
                Button { model.retry() } label: {
                    Label("Retry", systemImage: "arrow.clockwise")
                }
                .buttonStyle(FluxButtonStyle(kind: .filled))
                .padding(.top, 6)
            case .paired(let name):
                Image(systemName: "checkmark.circle")
                    .font(.system(size: 24))
                    .foregroundStyle(tn.green)
                    .accessibilityHidden(true)
                Heading("\(name) is paired")
                Paragraph("What waits for you on \(name) shows here first. Send and Control have the tools for \(name).")
                    .onAppear {
                        let text: String = "\(name) is paired. What waits for you on \(name) shows here first."
                        AccessibilityNotification.Announcement(text).post()
                    }
            case .clear(let name):
                Heading(name.map { "Nothing on \($0) needs you" } ?? "Nothing needs you")
                Paragraph("Agents that wait for you, approvals, and pair requests show here first. What plays now, the clipboard, transfers, and the other agents follow.")
            }
        }
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

/// The 2 action tiles under the large tile: Send clipboard and Send files.
/// They are dimmed while no computer in scope is online.
private struct ActionTiles: View {
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @State private var ask: TargetAsk?

    var body: some View {
        let target = ToolTarget.of(model)
        let ready = ToolTarget.ready(target)
        HStack(spacing: TiledMetrics.gap) {
            ActionTile(icon: "doc.on.clipboard", ink: tn.accent, title: "Send clipboard", line: "Paste it on the computer", enabled: ready) {
                guard let clipboard = model.core.plugin(ClipboardPlugin.self) else { return }
                ToolTarget.run(target, title: "Send the clipboard to", ask: $ask) { d in
                    _ = clipboard.sendClipboard(to: d.id)
                }
            }
            ActionTile(icon: "doc.badge.arrow.up", ink: tn.magenta, title: "Send files", line: "Pick files on this Mac", enabled: ready) {
                ToolTarget.run(target, title: "Send files to", ask: $ask) { d in
                    ShareActions.pickFiles(to: d, model: model)
                }
            }
        }
        .targetPicker($ask)
    }
}

/// A tile with an icon, a label, and a line, for an action.
private struct ActionTile: View {
    let icon: String
    let ink: Color
    let title: String
    let line: String
    let enabled: Bool
    let action: () -> Void
    @Environment(\.tn) private var tn

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous)
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                Image(systemName: icon)
                    .font(.system(size: 20))
                    .foregroundStyle(enabled ? ink : tn.sub)
                Text(title)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(tn.text)
                Text(line)
                    .font(.system(size: 11))
                    .foregroundStyle(tn.sub)
            }
            .multilineTextAlignment(.leading)
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 72, alignment: .topLeading)
            .background(shape.fill(tn.tile))
            .overlay(shape.strokeBorder(tn.line, lineWidth: 1))
            .contentShape(shape)
        }
        .buttonStyle(TilePressStyle())
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
    }
}
