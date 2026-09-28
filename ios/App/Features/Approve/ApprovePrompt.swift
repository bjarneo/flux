import FluxKit
import Observation
import SwiftUI

/// Whether the approval sheet shows. It shows for each new request. The user
/// can swipe it away while the request waits, and the banner or the
/// notification shows it again.
struct ApprovePresentation: Equatable {
    /// The request of the sheet, or nil.
    private(set) var request: String?
    private(set) var hidden = false

    var isPresented: Bool { request != nil && !hidden }

    /// The plugin shows another request, or none.
    mutating func shownChanged(_ id: String?) {
        if id != request { hidden = false }
        request = id
    }

    mutating func present() { hidden = false }

    /// The user swiped the sheet away. It returns true when the sheet showed
    /// a result, which then closes, because no banner brings a result back.
    mutating func dismissed(open: Bool) -> Bool {
        guard request != nil else { return false }
        if open {
            hidden = true
            return false
        }
        return true
    }
}

/// The time left of a request.
enum ApproveCountdown {
    /// Whole seconds, rounded up, never below 0.
    static func secondsLeft(until deadline: Date, now: Date) -> Int {
        max(0, Int(deadline.timeIntervalSince(now).rounded(.up)))
    }

    /// The part of the wait that is left, from 1 to 0.
    static func fractionLeft(until deadline: Date, total: Int, now: Date) -> Double {
        guard total > 0 else { return 0 }
        return min(1, max(0, deadline.timeIntervalSince(now) / Double(total)))
    }
}

/// The presentation of the approval sheet, for the plugin and the banner.
@MainActor
@Observable
final class ApprovePresenter {
    static let shared = ApprovePresenter()

    var state = ApprovePresentation()

    private init() {}
}

@MainActor
enum ApproveFeature {
    /// Lets the plugin show the sheet for each new request and for a tap
    /// on its notification.
    static func didLaunch(model: AppModel) {
        guard let plugin = model.core.plugin(ApprovePlugin.self) else { return }
        plugin.model.present = { ApprovePresenter.shared.state.present() }
    }
}

/// Shows the approval sheet over the whole app while a request waits, and the
/// result of an enrollment or a failure after it.
struct ApproveRoot: ViewModifier {
    @Environment(AppModel.self) private var model

    func body(content: Content) -> some View {
        if let plugin = model.core.plugin(ApprovePlugin.self) {
            let presenter = ApprovePresenter.shared
            content
                .sheet(isPresented: Binding(
                    get: { presenter.state.isPresented },
                    set: { shown in
                        if !shown, presenter.state.dismissed(open: plugin.model.current != nil) { plugin.closeResult() }
                    }
                )) {
                    ApprovePromptSheet(plugin: plugin)
                }
                .onChange(of: plugin.model.shown?.id, initial: true) { _, id in presenter.state.shownChanged(id) }
        } else {
            content
        }
    }
}

/// The sheet of the open request, from the plugin.
struct ApprovePromptSheet: View {
    let plugin: ApprovePlugin

    private var model: ApproveModel { plugin.model }

    var body: some View {
        if let r = model.shown {
            ApprovePromptView(request: r, phase: model.phase, deadline: model.deadline, texts: .current,
                              approve: { plugin.approve() }, deny: { plugin.deny() }, done: { plugin.closeResult() })
        }
    }
}

/// 1 request from a computer, with Approve and Deny. Approve asks for Face ID
/// or Touch ID, and this iPhone signs only after it. docs/approve.md is the
/// design.
struct ApprovePromptView: View {
    let request: ApproveRequest
    let phase: ApprovePhase
    let deadline: Date?
    let texts: ApproveTexts
    let approve: () -> Void
    let deny: () -> Void
    let done: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                switch phase {
                case .enrolled(let code):
                    EnrolledResult(code: code, symbol: texts.symbol, done: done)
                case .failed(let message):
                    FailedResult(message: message, done: done)
                case .ask, .working:
                    AskContent(request: request, deadline: deadline, texts: texts, working: phase == .working,
                               approve: approve, deny: deny)
                }
            }
            .padding(24)
            .padding(.top, 20)
            .frame(maxWidth: 560)
            .frame(maxWidth: .infinity)
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDragIndicator(.visible)
        .interactiveDismissDisabled(phase == .working)
    }
}

private struct AskContent: View {
    let request: ApproveRequest
    let deadline: Date?
    let texts: ApproveTexts
    let working: Bool
    let approve: () -> Void
    let deny: () -> Void

    var body: some View {
        Image(systemName: texts.symbol)
            .font(.system(size: 64, weight: .light))
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        Text(ApproveMessage.question(request))
            .font(.title2.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        VStack(spacing: 6) {
            ForEach(ApprovePlugin.details(request), id: \.self) { line in
                Text(line)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        if request.kind == .approve {
            Text("Approve only if you just typed the command.")
                .font(.callout.weight(.medium))
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
        if let deadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(spacing: 6) {
                    ProgressView(value: ApproveCountdown.fractionLeft(until: deadline, total: request.timeoutSeconds, now: context.date))
                        .tint(.pink)
                    Text("Expires in \(ApproveCountdown.secondsLeft(until: deadline, now: context.date)) s")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 8)
        }
        VStack(spacing: 10) {
            Button(action: approve) {
                Label(request.kind == .approve ? "Approve" : "Enroll", systemImage: texts.symbol)
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.borderedProminent)
            Button(role: .destructive, action: deny) {
                Text("Deny")
                    .font(.headline)
                    .frame(maxWidth: .infinity, minHeight: 34)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(working)
        .padding(.top, 6)
        if working {
            HStack(spacing: 8) {
                ProgressView()
                Text(texts.working).foregroundStyle(.secondary)
            }
        }
    }
}

private struct EnrolledResult: View {
    let code: String
    let symbol: String
    let done: () -> Void

    var body: some View {
        Image(systemName: symbol)
            .font(.system(size: 64, weight: .light))
            .foregroundStyle(.tint)
            .accessibilityHidden(true)
        Text("Compare the key code").font(.title2.weight(.semibold))
        Text("Check that the terminal shows this code. Then type y in the terminal.")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        Text(code)
            .font(.system(size: 26, weight: .semibold, design: .monospaced))
            .kerning(2)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
            .textSelection(.enabled)
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .background(Color(.tertiarySystemFill), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        Button(action: done) {
            Text("Done").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}

private struct FailedResult: View {
    let message: String
    let done: () -> Void

    var body: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 52, weight: .light))
            .foregroundStyle(.orange)
            .accessibilityHidden(true)
        Text(message)
            .font(.title3.weight(.semibold))
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        Text("The computer asks for the password.")
            .foregroundStyle(.secondary)
        Button(action: done) {
            Text("Close").font(.headline).frame(maxWidth: .infinity, minHeight: 34)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }
}
