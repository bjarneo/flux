import FluxKit
import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The Inbox with no items in scope. A large tile with the active border
/// takes the master position and tells why the Inbox is empty, so that an
/// empty Inbox is not a false all-clear. Before the first pairing, it is
/// the pairing guide. Under it, the notices and the 2 most used actions.
struct EmptyInbox: View {
    /// The items of all computers.
    let all: [InboxItem]
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var filesTarget: DeviceSnapshot?
    @State private var pickingFiles = false

    /// What the large tile shows, in the order of the checks.
    enum Mode: Hashable {
        case off, guide, connecting, offline, paired(String), clear

        /// True while the large tile shows a new pairing.
        var isPaired: Bool {
            if case .paired = self { return true }
            return false
        }
    }

    var body: some View {
        let devices = model.state.devices
        let anyPaired = devices.contains { $0.paired }
        let reach = Inbox.reach(scope: model.scope, devices: devices)
        let offline = anyPaired && reach.noneOnline
        let mode = Self.mode(enabled: model.state.enabled, paired: anyPaired, offline: offline,
                             connecting: model.connecting, welcome: InboxTexts.newlyPaired(model))
        ScrollView {
            VStack(spacing: TiledMetrics.gap) {
                EmptyTile {
                    switch mode {
                    case .off: off
                    case .guide: PairGuide()
                    case .connecting: connecting(reach)
                    case .offline: offlineTile(reach)
                    case .paired(let name): PairedTile(name: name)
                    case .clear: clear
                    }
                }
                .id(mode)
                .transition(.opacity)
                if anyPaired {
                    InboxNotices(scoped: [], all: all, showOffline: !offline, showPaired: !mode.isPaired)
                    HStack(spacing: TiledMetrics.gap) {
                        ActionTile(icon: "doc.on.clipboard", title: "Send clipboard", line: "Paste it on the computer",
                                   tint: tn.accent, enabled: !offline) { SendTools.sendClipboard(model) }
                            .frame(maxHeight: .infinity)
                        ActionTile(icon: "doc.badge.arrow.up", title: "Send files", line: "Pick files on this iPhone",
                                   tint: tn.magenta, enabled: !offline) { sendFiles() }
                            .frame(maxHeight: .infinity)
                    }
                    .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(.horizontal, TiledMetrics.gutter)
            .padding(.top, 4)
            .padding(.bottom, 16)
            .animation(Motion.standard(reduceMotion), value: mode)
        }
        .fileImporter(isPresented: $pickingFiles, allowedContentTypes: [.data], allowsMultipleSelection: true) { result in
            guard let d = filesTarget else { return }
            switch result {
            case .success(let urls): ShareFeature.send(picked: urls, to: d, model: model)
            case .failure(let error): model.show("Cannot open the files: \(error.localizedDescription)")
            }
        }
    }

    static func mode(enabled: Bool, paired: Bool, offline: Bool, connecting: Bool, welcome: String?) -> Mode {
        if !enabled { return .off }
        if !paired { return .guide }
        if offline && connecting { return .connecting }
        if offline { return .offline }
        if let welcome { return .paired(welcome) }
        return .clear
    }

    private func sendFiles() {
        TargetRun.run(model, can: SendTools.canShare(model), title: "Send files to") { d in
            filesTarget = d
            pickingFiles = true
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

    private func connecting(_ reach: InboxReach) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                FluxSpinner(size: 20)
                EmptyTitle(text: reach.offline.count == 1 ? "Connecting to \(reach.offline[0].name)" : "Connecting to your computers")
            }
            EmptyLine(text: "What waits for you shows here when the connection is ready.")
        }
    }

    private func offlineTile(_ reach: InboxReach) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "wifi.exclamationmark")
                .font(.title2)
                .foregroundStyle(tn.yellow)
                .accessibilityHidden(true)
            EmptyTitle(text: reach.offline.count == 1 ? "\(reach.offline[0].name) is not reachable" : "No computer is reachable")
            EmptyLine(text: "Check that Flux runs on the computer, and that this iPhone can reach it on this network or on Tailscale.")
            EmptyLine(text: "The Inbox shows what waits on a computer only while the computer is reachable.")
            Button { model.retry() } label: {
                Label("Retry", systemImage: "arrow.clockwise")
            }
            .buttonStyle(FluxButtonStyle(kind: .filled))
            .padding(.top, 4)
        }
    }

    private var clear: some View {
        VStack(alignment: .leading, spacing: 10) {
            EmptyTitle(text: InboxTexts.nothing(model))
            EmptyLine(text: "Agents that wait for you, approvals, and pair requests show here first. What plays now, the clipboard, transfers, and the other agents follow.")
        }
    }
}

/// The large tile of an empty Inbox. It takes the place of the master tile,
/// so it has the active border.
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

/// The success state of a new pairing. VoiceOver reads it when it shows.
private struct PairedTile: View {
    let name: String
    @Environment(\.tn) private var tn

    var body: some View {
        let text = "\(name) is paired. What waits for you on \(name) shows here first. Send and Control have the tools for \(name)."
        VStack(alignment: .leading, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .font(.title2)
                .foregroundStyle(tn.green)
                .accessibilityHidden(true)
            EmptyTitle(text: "\(name) is paired")
            EmptyLine(text: "What waits for you on \(name) shows here first. Send and Control have the tools for \(name).")
        }
        .accessibilityElement(children: .combine)
        .onAppear { UIAccessibility.post(notification: .announcement, argument: text) }
    }
}

/// The Inbox before the first pairing: what Flux does, how to set up Flux
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

/// A tile that runs 1 action: an icon, a label, and a line. It is dimmed
/// and takes no taps while no computer in scope is online.
private struct ActionTile: View {
    let icon: String
    let title: String
    let line: String
    let tint: Color
    let enabled: Bool
    let action: () -> Void
    @Environment(\.tn) private var tn
    @ScaledMetric(relativeTo: .body) private var iconSize: CGFloat = 24

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: iconSize))
                    .foregroundStyle(enabled ? tint : tn.sub)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(tn.text)
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(tn.sub)
                }
                .multilineTextAlignment(.leading)
            }
            .padding(14)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .frame(minHeight: 88)
        }
        .buttonStyle(TiledPressStyle(fill: tn.tile, border: tn.line))
        .disabled(!enabled)
        .opacity(enabled ? 1 : TiledMetrics.disabledAlpha)
    }
}
