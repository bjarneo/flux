import FluxKit
import SwiftUI
import UserNotifications

/// The texts of the chats about the computers.
@MainActor
enum ChatTexts {
    /// The context line of Chats, such as "2 need you · 1 of 2 online".
    /// `needs` counts the items of all computers that need the user.
    static func context(_ model: AppModel, needs: Int) -> String {
        ScreenWords.join(needs > 0 ? "\(needs) need you" : "nothing needs you", ScreenWords.online(model))
    }

    /// The line under the name of a computer in its chat: the link and the
    /// battery, such as "connected · 82%, charging", or "not reachable".
    static func link(_ model: AppModel, _ d: DeviceSnapshot) -> String {
        guard d.online else { return "not reachable" }
        guard let b = model.core.plugin(BatteryPlugin.self)?.model.computers[d.id] else { return "connected" }
        return "connected · \(b.charge)%" + (b.charging ? ", charging" : "")
    }

    /// The title of the computers of a chat while the links connect.
    nonisolated static func connecting(_ reach: InboxReach) -> String {
        reach.offline.count == 1 ? "Connecting to \(reach.offline[0].name)" : "Connecting to your computers"
    }

    /// The line for the computers of a chat that are not reachable.
    nonisolated static func offlineLine(_ reach: InboxReach) -> String {
        if reach.offline.count == 1, let d = reach.offline.first {
            return "\(d.name) is not reachable."
        }
        return "\(reach.offline.count) computers are not reachable."
    }

    /// True when a chat tells that its computers are not reachable. While
    /// the links connect after a start, the chat does not say it.
    static func offlineShows(_ model: AppModel, computer: String?) -> Bool {
        !model.connecting && !Inbox.reach(scope: computer, devices: model.state.devices).offline.isEmpty
    }

    /// The name of the computer that paired last, while the chat of
    /// `computer` or the list of chats with nil shows it.
    static func newlyPaired(_ model: AppModel, computer: String?) -> String? {
        guard let id = model.newlyPairedId, computer == nil || computer == id else { return nil }
        return model.device(id)?.name
    }
}

/// What a chat tells under its entries, or the list of chats on top: that
/// the links connect, a new pairing, the computers that are not reachable,
/// and in the list the notifications. `computer` is the computer of the
/// chat, or nil for the list. The rows of the list show which computers
/// are not reachable, so the list tells it only with `offline`.
struct ChatNotices: View {
    let computer: String?
    var offline = true
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @AppStorage("inbox.notificationsHidden") private var notificationsHidden = false

    var body: some View {
        let reach = Inbox.reach(scope: computer, devices: model.state.devices)
        let status = NotificationAccess.shared.status
        let asks = computer == nil && !model.demo && !notificationsHidden && model.state.devices.contains { $0.paired }
        VStack(alignment: .leading, spacing: 4) {
            if model.connecting && reach.noneOnline {
                HStack(spacing: 10) {
                    FluxSpinner(size: 16)
                    Text(ChatTexts.connecting(reach))
                        .font(.footnote)
                        .foregroundStyle(tn.sub)
                }
                .padding(.horizontal, 4)
                .accessibilityElement(children: .combine)
            }
            if let name = ChatTexts.newlyPaired(model, computer: computer) {
                Notice(mark: .paired, text: "\(name) is paired. What waits for you on \(name) shows here first.", strong: true) {
                    EmptyView()
                }
            }
            if offline && ChatTexts.offlineShows(model, computer: computer) {
                Notice(mark: .offline, text: ChatTexts.offlineLine(reach), strong: false) {
                    Button("Retry") { model.retry() }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
            if asks && status == .notDetermined {
                Notice(mark: .bell, text: "Allow notifications, so that Flux can show when an agent needs you.", strong: false) {
                    Button("Allow") { NotificationAccess.shared.ask() }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                    Button("Hide") { notificationsHidden = true }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            } else if asks && status == .denied {
                Notice(mark: .bell, text: "Notifications are off for Flux, so sudo approvals and agent alerts do not reach this iPhone. Turn them on in the Settings app.", strong: false) {
                    Button("Open Settings") { NotificationAccess.shared.turnOn(model: model) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                    Button("Hide") { notificationsHidden = true }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
        }
    }
}

/// The mark of a notice.
enum NoticeMark {
    case paired, offline, bell
}

/// 1 notice: a mark, the text, and the actions under the text. The actions
/// go under each other at a large text size.
struct Notice<Actions: View>: View {
    let mark: NoticeMark
    let text: String
    /// True for `text`, false for `sub`.
    let strong: Bool
    @ViewBuilder let actions: Actions
    @Environment(\.tn) private var tn

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            markView
                .frame(width: 18, height: 18)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 0) {
                Text(text)
                    .font(.footnote)
                    .foregroundStyle(strong ? tn.text : tn.sub)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 0) { actions }
                    VStack(alignment: .leading, spacing: 0) { actions }
                }
                // The text of the first button lines up with the text above.
                .padding(.leading, -12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 4)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var markView: some View {
        switch mark {
        case .paired:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(tn.green).accessibilityHidden(true)
        case .offline:
            LinkDot(online: false)
        case .bell:
            Image(systemName: "bell.badge").foregroundStyle(tn.yellow).accessibilityHidden(true)
        }
    }
}
