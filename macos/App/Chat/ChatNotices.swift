import Accessibility
import AppKit
import FluxKit
import SwiftUI

/// The texts of the notices of the list of chats and of the chat of 1
/// computer.
struct ChatStatus: Equatable {
    /// True for the list of chats, false for the chat of 1 computer.
    let inList: Bool
    /// The computers that are not reachable, while Flux does not connect.
    let offline: [String]
    /// The computer that Flux connects to, or "" for more computers, while
    /// the computers are not online. It is nil when Flux does not connect.
    let connecting: String?
    /// The computer that paired in the last 6 seconds, in its own chat.
    let pairedName: String?

    /// "omarchy is not reachable." or the form for more computers.
    var offlineLine: String? {
        switch offline.count {
        case 0: return nil
        case 1: return "\(offline[0]) is not reachable."
        default: return "\(offline.count) computers are not reachable."
        }
    }

    /// The notices of the list. The rows show each computer that is not
    /// reachable, so the list tells it only when no computer is online.
    @MainActor
    static func list(_ model: AppModel) -> ChatStatus {
        let reach = Inbox.reach(scope: nil, devices: model.state.devices)
        guard reach.noneOnline else { return ChatStatus(inList: true, offline: [], connecting: nil, pairedName: nil) }
        if model.connecting {
            return ChatStatus(inList: true, offline: [], connecting: reach.offline.count == 1 ? reach.offline[0].name : "", pairedName: nil)
        }
        return ChatStatus(inList: true, offline: reach.offline.map(\.name), connecting: nil, pairedName: nil)
    }

    /// The notices of the chat of `device`.
    @MainActor
    static func computer(_ model: AppModel, _ device: DeviceSnapshot) -> ChatStatus {
        let away = !device.online
        return ChatStatus(inList: false,
                          offline: away && !model.connecting ? [device.name] : [],
                          connecting: away && model.connecting ? device.name : nil,
                          pairedName: model.newlyPairedId == device.id ? device.name : nil)
    }
}

/// The notices of the list or of a chat: that Flux connects, a new
/// pairing, the computers that are not reachable, and in the list the
/// Local Network permission. Flux for macOS has no notification notice.
struct ChatNotices: View {
    let status: ChatStatus
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let localNetworkOff = status.inList && model.state.localNetworkDenied && !model.state.devices.contains(where: \.online)
        VStack(spacing: TiledMetrics.gap) {
            if let name = status.connecting {
                HStack(spacing: 10) {
                    FluxSpinner(size: 14)
                    Text(name.isEmpty ? "Connecting to your computers" : "Connecting to \(name)")
                        .font(.system(size: 12))
                        .foregroundStyle(tn.sub)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 10)
                .accessibilityElement(children: .combine)
            }
            if let name = status.pairedName {
                NoticeRow(icon: "checkmark.circle", ink: tn.green, text: "\(name) is paired. Its files, clips, and approvals show here.")
                    .onAppear {
                        let text: String = "\(name) is paired. Its files, clips, and approvals show here."
                        AccessibilityNotification.Announcement(text).post()
                    }
            }
            if let offline = status.offlineLine {
                NoticeRow(ring: true, text: offline) {
                    Button("Retry") { model.retry() }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
            if localNetworkOff {
                NoticeRow(icon: "wifi.exclamationmark", ink: tn.yellow, text: LocalNetworkNotice.text) {
                    Button("Open System Settings") { NSWorkspace.shared.open(LocalNetworkNotice.settings) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
        }
    }
}

/// 1 notice: a mark, the text, and the actions at the end of the row.
private struct NoticeRow<Actions: View>: View {
    var icon: String?
    var ink: Color?
    var dot: Color?
    var ring = false
    let text: String
    let actions: Actions
    @Environment(\.tn) private var tn

    init(icon: String? = nil, ink: Color? = nil, dot: Color? = nil, ring: Bool = false, text: String,
         @ViewBuilder actions: () -> Actions) {
        self.icon = icon
        self.ink = ink
        self.dot = dot
        self.ring = ring
        self.text = text
        self.actions = actions()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Group {
                if let icon {
                    Image(systemName: icon)
                        .font(.system(size: 15))
                        .foregroundStyle(ink ?? tn.sub)
                } else if let dot {
                    Circle().fill(dot).frame(width: 8, height: 8)
                } else if ring {
                    LinkDot(online: false)
                }
            }
            .frame(width: 18)
            .accessibilityHidden(true)
            Text(text)
                .font(.system(size: 12))
                .foregroundStyle(tn.text)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            actions
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, minHeight: 36, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous).fill(tn.offTile))
        .overlay(RoundedRectangle(cornerRadius: TiledMetrics.tileCorner, style: .continuous).strokeBorder(tn.line, lineWidth: 1))
    }
}

extension NoticeRow where Actions == EmptyView {
    init(icon: String? = nil, ink: Color? = nil, dot: Color? = nil, ring: Bool = false, text: String) {
        self.init(icon: icon, ink: ink, dot: dot, ring: ring, text: text) { EmptyView() }
    }
}
