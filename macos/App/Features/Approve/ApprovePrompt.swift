import AppKit
import FluxKit
import SwiftUI

/// The window of the approval prompt. It floats over other windows, like an
/// incoming call, and it closes when the request ends.
@MainActor
final class ApprovePromptWindow {
    private static var window: NSWindow?
    /// The app model, for the tint and the light or dark mode of the theme.
    private static weak var app: AppModel?

    /// Lets the plugin bring the prompt to the front for each new request.
    static func install(model: AppModel) {
        app = model
        guard let plugin = model.core.plugin(ApprovePlugin.self) else { return }
        plugin.model.present = { show(plugin) }
    }

    static func show(_ plugin: ApprovePlugin) {
        let w = window ?? make(plugin)
        if window == nil {
            w.center()
            window = w
        }
        NSApp.activate(ignoringOtherApps: true)
        w.makeKeyAndOrderFront(nil)
    }

    /// The prompt has a fixed size. A window that follows the SwiftUI size
    /// loops in Auto Layout when the wrapped text changes height.
    private static let size = NSSize(width: 460, height: 440)

    private static func make(_ plugin: ApprovePlugin) -> NSWindow {
        // The prompt keeps its layout and its colors. It takes only the tint and the light or dark mode of the theme.
        let host = NSHostingController(rootView: ApprovePromptView(plugin: plugin) { window?.orderOut(nil) }.themeWindow(app, surfaces: false))
        host.sizingOptions = []
        let w = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.contentViewController = host
        w.setContentSize(size)
        w.title = "Flux Approval"
        w.level = .floating
        w.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        w.isReleasedWhenClosed = false
        return w
    }
}

/// 1 request from a computer, with Approve and Deny. Approve asks for Touch
/// ID, and this Mac signs only after it. docs/approve.md is the design.
struct ApprovePromptView: View {
    let plugin: ApprovePlugin
    let close: () -> Void

    private var model: ApproveModel { plugin.model }

    var body: some View {
        VStack(spacing: 14) {
            switch model.phase {
            case .enrolled(let code):
                EnrolledView(code: code) { plugin.closeResult() }
            case .failed(let message):
                FailedView(message: message) { plugin.closeResult() }
            case .ask, .working:
                if let r = model.shown {
                    AskView(request: r, replacesKey: plugin.replacesKey(r), deadline: model.deadline, working: model.phase == .working,
                            approve: { plugin.approve() }, deny: { plugin.deny() })
                }
            }
        }
        .padding(28)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // The request ends: approved, denied, cancelled by the computer, or
        // timed out. The result of an enrollment or a failure stays.
        .onChange(of: model.shown == nil) { _, gone in
            if gone { close() }
        }
    }
}

private struct AskView: View {
    let request: ApproveRequest
    let replacesKey: Bool
    let deadline: Date?
    let working: Bool
    let approve: () -> Void
    let deny: () -> Void

    var body: some View {
        Image(systemName: "touchid")
            .font(.system(size: 56, weight: .light))
            .foregroundStyle(.tint)
        Text(ApproveMessage.question(request))
            .font(.title2)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        ForEach(ApprovePlugin.details(request, replacesKey: replacesKey), id: \.self) { line in
            Text(line)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        if request.kind == .approve {
            Text("Approve only if you just typed the command.")
                .foregroundStyle(.red)
                .multilineTextAlignment(.center)
        }
        if let deadline {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(deadline.timeIntervalSince(context.date).rounded(.up)))
                Text("Expires in \(left) s")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        HStack(spacing: 12) {
            Button("Deny", role: .cancel, action: deny)
                .keyboardShortcut(.cancelAction)
            Button(action: approve) {
                Label(request.kind == .approve ? "Approve" : "Enroll", systemImage: "touchid")
            }
            .buttonStyle(.borderedProminent)
            .disabled(working)
        }
        .controlSize(.large)
        .padding(.top, 6)
        if working {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Touch the Touch ID sensor.").foregroundStyle(.secondary)
            }
        }
    }
}

private struct EnrolledView: View {
    let code: String
    let done: () -> Void

    var body: some View {
        Image(systemName: "touchid")
            .font(.system(size: 56, weight: .light))
            .foregroundStyle(.tint)
        Text("Compare the key code").font(.title2)
        Text("Check that the terminal shows this code. Then type y in the terminal.")
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        Text(code)
            .font(.system(size: 26, weight: .semibold, design: .monospaced))
            .kerning(2)
            .textSelection(.enabled)
            .padding(.horizontal, 18)
            .padding(.vertical, 10)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
        Button("Done", action: done)
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
    }
}

private struct FailedView: View {
    let message: String
    let done: () -> Void

    var body: some View {
        Image(systemName: "exclamationmark.triangle")
            .font(.system(size: 48, weight: .light))
            .foregroundStyle(.orange)
        Text(message)
            .font(.title3)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
        Text("The computer asks for the password.")
            .foregroundStyle(.secondary)
        Button("Close", action: done)
            .keyboardShortcut(.defaultAction)
            .controlSize(.large)
    }
}
