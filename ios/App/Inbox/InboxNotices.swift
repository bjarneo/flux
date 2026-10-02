import FluxKit
import SwiftUI
import UserNotifications

/// The texts of the Inbox about the computers in scope.
@MainActor
enum InboxTexts {
    /// The name of the computer in scope, or nil for all computers.
    static func scopeName(_ model: AppModel) -> String? {
        model.scope.flatMap { model.device($0)?.name }
    }

    /// The title of an Inbox with nothing to do. In a scope, it names the computer.
    static func nothing(_ model: AppModel) -> String {
        scopeName(model).map { "Nothing on \($0) needs you" } ?? "Nothing needs you"
    }

    /// The count of the items that need the user, as a sentence.
    nonisolated static func needs(_ count: Int) -> String {
        count == 1 ? "1 item needs you" : "\(count) items need you"
    }

    /// The line for the computers in scope that are not reachable.
    nonisolated static func offlineLine(_ reach: InboxReach) -> String {
        if reach.offline.count == 1, let d = reach.offline.first {
            return "\(d.name) is not reachable. Its agents do not show here."
        }
        return "\(reach.offline.count) computers are not reachable. Their agents do not show here."
    }

    /// True when the Inbox tells that computers in scope are not reachable.
    /// While the links connect after a start, the Inbox does not say it.
    static func offlineShows(_ model: AppModel) -> Bool {
        !model.connecting && !Inbox.reach(scope: model.scope, devices: model.state.devices).offline.isEmpty
    }

    /// The name of the computer that paired last, while the Inbox shows it.
    static func newlyPaired(_ model: AppModel) -> String? {
        guard let id = model.newlyPairedId, model.scope == nil || model.scope == id else { return nil }
        return model.device(id)?.name
    }
}

/// The status line above the master: how many items need the user, then
/// the computers in scope that are not reachable, with Retry. The other
/// notices follow under it.
struct StatusLine: View {
    /// The items in scope.
    let scoped: [InboxItem]
    /// The items of all computers.
    let all: [InboxItem]
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let needs = Inbox.needsYou(scoped)
        let offline = InboxTexts.offlineShows(model)
        let reach = Inbox.reach(scope: model.scope, devices: model.state.devices)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                HStack(alignment: .top, spacing: 10) {
                    if needs > 0 {
                        Circle().fill(tn.red).frame(width: 8, height: 8).padding(.top, 5)
                            .accessibilityHidden(true)
                    } else if offline {
                        LinkDot(online: false).padding(.top, 5)
                    }
                    VStack(alignment: .leading, spacing: 2) {
                        if needs > 0 {
                            Text(InboxTexts.needs(needs))
                                .font(.subheadline.weight(.semibold))
                                .foregroundStyle(tn.text)
                        } else {
                            Text(InboxTexts.nothing(model))
                                .font(.subheadline)
                                .foregroundStyle(tn.sub)
                        }
                        if offline {
                            Text(InboxTexts.offlineLine(reach))
                                .font(.footnote)
                                .foregroundStyle(tn.sub)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityElement(children: .combine)
                if offline {
                    Button("Retry") { model.retry() }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
            .frame(minHeight: offline ? 44 : 32)
            .padding(.leading, 4)
            InboxNotices(scoped: scoped, all: all, showOffline: false)
        }
    }
}

/// What the Inbox tells next to its items: a new pairing, the items on
/// other computers that need the user, the computers in scope that are not
/// reachable, and the notifications. `showOffline` is false when the status
/// line or the large tile already tells that computers are not reachable.
/// `showPaired` is false when the large tile already shows a new pairing.
struct InboxNotices: View {
    let scoped: [InboxItem]
    let all: [InboxItem]
    var showOffline = true
    var showPaired = true
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn
    @AppStorage("inbox.notificationsHidden") private var notificationsHidden = false

    var body: some View {
        let elsewhere = Inbox.needsYou(all) - Inbox.needsYou(scoped)
        let reach = Inbox.reach(scope: model.scope, devices: model.state.devices)
        let status = NotificationAccess.shared.status
        let asks = !model.demo && !notificationsHidden && model.state.devices.contains { $0.paired }
        VStack(alignment: .leading, spacing: 4) {
            if showPaired, let name = InboxTexts.newlyPaired(model) {
                Notice(mark: .paired, text: "\(name) is paired. What waits for you on \(name) shows here first.", strong: true) {
                    EmptyView()
                }
            }
            if elsewhere > 0 {
                Notice(mark: .needs, text: elsewhere == 1 ? "1 item on another computer needs you"
                    : "\(elsewhere) items on other computers need you", strong: true) {
                    Button("Show all computers") { model.setScope(nil) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
            if showOffline && InboxTexts.offlineShows(model) {
                Notice(mark: .offline, text: InboxTexts.offlineLine(reach), strong: false) {
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
    case paired, needs, offline, bell
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
        case .needs:
            Circle().fill(tn.red).frame(width: 8, height: 8).accessibilityHidden(true)
        case .offline:
            LinkDot(online: false)
        case .bell:
            Image(systemName: "bell.badge").foregroundStyle(tn.yellow).accessibilityHidden(true)
        }
    }
}
