import FluxKit
import SwiftUI

/// A question for the computer of an action, such as "Send the clipboard
/// to". The app shows it while more than 1 computer can take the action.
struct TargetRequest: Identifiable {
    let id = UUID()
    let title: String
    let devices: [DeviceSnapshot]
    let action: @MainActor (DeviceSnapshot) -> Void
}

/// Finds the computer of a Send or Control action, see `Inbox.target`.
@MainActor
enum TargetRun {
    /// Runs `action` on the only computer that can take it. With more than
    /// 1, the app asks which one first. With none, a toast tells why.
    static func run(_ model: AppModel, can: (DeviceSnapshot) -> Bool, title: String,
                    action: @escaping @MainActor (DeviceSnapshot) -> Void) {
        switch Inbox.target(scope: model.scope, devices: model.state.devices, can: can) {
        case .one(let d): action(d)
        case .ask(let list): model.targetRequest = TargetRequest(title: title, devices: list, action: action)
        case .unavailable(let d): model.show(noTarget(d))
        }
    }

    /// True when a computer in scope can take the action now.
    static func enabled(_ model: AppModel, can: (DeviceSnapshot) -> Bool) -> Bool {
        if case .unavailable = Inbox.target(scope: model.scope, devices: model.state.devices, can: can) { return false }
        return true
    }

    /// True when a paired computer in scope has the feature, also while it
    /// is not reachable. Before the first pairing, each tool shows, so that
    /// a destination shows what it holds.
    static func shows(_ model: AppModel, can: (DeviceSnapshot) -> Bool) -> Bool {
        let devices = model.state.devices
        if !devices.contains(where: { $0.paired }) { return true }
        return Inbox.hasFeature(scope: model.scope, devices: devices, can: can)
    }

    /// The only computer of the general target, or nil.
    static func single(_ model: AppModel) -> DeviceSnapshot? {
        if case .one(let d) = Inbox.target(scope: model.scope, devices: model.state.devices) { return d }
        return nil
    }

    /// Why an action has no computer, in 1 sentence without a period.
    nonisolated static func noTarget(_ d: DeviceSnapshot?) -> String {
        guard let d else { return "No computer is online" }
        return d.online ? "Update Flux on \(d.name) to use this" : "\(d.name) is not reachable"
    }
}

/// The tools that send to the computer in scope, for Send and the Inbox.
@MainActor
enum SendTools {
    /// The computers that take the clipboard, see `SendClipboardQuickAction`.
    static func canClipboard(_ model: AppModel) -> (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(ClipboardPlugin.self) != nil
        return { has && $0.accepts(PacketType.clipboard) }
    }

    /// The computers that take files, see `SendFilesQuickAction`.
    static func canShare(_ model: AppModel) -> (DeviceSnapshot) -> Bool {
        let has = model.core.plugin(SharePlugin.self) != nil
        return { has && $0.accepts(PacketType.share) }
    }

    /// Sends the clipboard: an image, or else its text.
    static func sendClipboard(_ model: AppModel) {
        TargetRun.run(model, can: canClipboard(model), title: "Send the clipboard to") { d in
            if model.demo {
                model.show(DemoMode.sendsNothing)
                return
            }
            model.core.plugin(ClipboardPlugin.self)?.sendClipboard(to: d.id)
        }
    }
}

/// The line at the top of Send and Control: the computer that the tools go
/// to, or why no computer can take them, with the next step.
struct TargetLine: View {
    /// "Sends to" or "Acts on".
    let verb: String
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let devices = model.state.devices
        let paired = devices.contains { $0.paired }
        HStack(spacing: 8) {
            switch Inbox.target(scope: model.scope, devices: devices) {
            case .one(let d):
                LinkDot(online: true)
                Text("\(verb) \(d.name)")
                    .font(.subheadline)
                    .foregroundStyle(tn.text)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .ask(let list):
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.subheadline)
                    .foregroundStyle(tn.sub)
                    .accessibilityHidden(true)
                Text("\(list.count) computers are online. Flux asks which one.")
                    .font(.subheadline)
                    .foregroundStyle(tn.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
            case .unavailable(let d):
                LinkDot(online: false)
                Text(paired ? TargetRun.noTarget(d) + "." : "Pair a computer to use these tools.")
                    .font(.subheadline)
                    .foregroundStyle(tn.sub)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if paired {
                    Button("Retry") { model.retry() }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                } else {
                    Button("Pair") { model.select(.computers) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                        .accessibilityHint("Opens Computers")
                }
            }
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 4)
    }
}

/// Shows the question of `AppModel.targetRequest`: 1 button for each
/// computer, and Cancel.
struct TargetPickerModifier: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        let request = model.targetRequest
        content.confirmationDialog(
            request?.title ?? "",
            isPresented: Binding(get: { model.targetRequest != nil }, set: { if !$0 { model.targetRequest = nil } }),
            titleVisibility: .visible,
            presenting: request
        ) { r in
            ForEach(r.devices) { d in
                Button(d.name) { r.action(d) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

extension View {
    /// Shows the question for the computer of an action, see `TargetRun`.
    func targetPicker() -> some View {
        modifier(TargetPickerModifier())
    }
}
