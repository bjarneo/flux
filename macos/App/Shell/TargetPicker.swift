import FluxKit
import SwiftUI

/// A question for the computer of an action, when more than 1 computer can take it.
struct TargetAsk: Identifiable {
    let id = UUID()
    /// The title of the dialog, such as "Send the clipboard to".
    let title: String
    let devices: [DeviceSnapshot]
    let run: (DeviceSnapshot) -> Void
}

/// Finds the computer of a tool and runs it.
@MainActor
enum ToolTarget {
    /// The computer for an action that the computers in `can` take, from the scope.
    static func of(_ model: AppModel, can: (DeviceSnapshot) -> Bool = { _ in true }) -> ActionTarget {
        Inbox.target(scope: model.scope, devices: model.state.devices, can: can)
    }

    /// Runs `action` on the only computer, or asks the user to pick 1 with
    /// the dialog of `targetPicker`. It does nothing without a computer.
    static func run(_ target: ActionTarget, title: String, ask: Binding<TargetAsk?>, _ action: @escaping (DeviceSnapshot) -> Void) {
        switch target {
        case .one(let d): action(d)
        case .ask(let list): ask.wrappedValue = TargetAsk(title: title, devices: list, run: action)
        case .unavailable: break
        }
    }

    /// True when the tool has a computer, now or after a choice.
    static func ready(_ target: ActionTarget) -> Bool {
        if case .unavailable = target { return false }
        return true
    }

    /// The device of a target with 1 computer.
    static func single(_ target: ActionTarget) -> DeviceSnapshot? {
        if case .one(let d) = target { return d }
        return nil
    }
}

extension View {
    /// Shows the dialog that asks for the computer of an action.
    func targetPicker(_ ask: Binding<TargetAsk?>) -> some View {
        modifier(TargetPicker(ask: ask))
    }
}

private struct TargetPicker: ViewModifier {
    @Binding var ask: TargetAsk?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            ask?.title ?? "",
            isPresented: Binding(get: { ask != nil }, set: { if !$0 { ask = nil } }),
            titleVisibility: .visible,
            presenting: ask
        ) { a in
            ForEach(a.devices) { d in
                Button(d.name) { a.run(d) }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}

/// The line at the top of Send and Control: the computer that the tools
/// act on, or why no computer can take them.
struct TargetLine: View {
    /// "Sends to" or "Acts on".
    let verb: String
    @Environment(AppModel.self) private var model
    @Environment(\.tn) private var tn

    var body: some View {
        let target = ToolTarget.of(model)
        HStack(spacing: 10) {
            switch target {
            case .one(let d):
                LinkDot(online: true)
                Text("\(verb) \(d.name)")
                    .font(.system(size: 13))
                    .foregroundStyle(tn.text)
                    .lineLimit(2)
                Spacer(minLength: 0)
            case .ask(let list):
                Image(systemName: "desktopcomputer")
                    .foregroundStyle(tn.sub)
                Text("\(list.count) computers are online. Flux asks which one.")
                    .font(.system(size: 13))
                    .foregroundStyle(tn.sub)
                Spacer(minLength: 0)
            case .unavailable(let d):
                LinkDot(online: false)
                if model.paired.isEmpty {
                    Text("Pair a computer to use these tools.")
                        .font(.system(size: 13))
                        .foregroundStyle(tn.sub)
                    Spacer(minLength: 8)
                    Button("Pair") { model.go(.computers) }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                } else {
                    Text(Self.noTarget(d) + ".")
                        .font(.system(size: 13))
                        .foregroundStyle(tn.sub)
                    Spacer(minLength: 8)
                    Button("Retry") { model.retry() }
                        .buttonStyle(FluxButtonStyle(kind: .text))
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(minHeight: 36)
    }

    /// Why no computer can take a tool: `d` is the computer in scope, or nil.
    static func noTarget(_ d: DeviceSnapshot?) -> String {
        guard let d else { return "No computer is online" }
        if !d.online { return "\(d.name) is not reachable" }
        return "Update Flux on \(d.name) to use this"
    }
}
