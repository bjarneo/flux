import SwiftUI
import FluxProto
import FluxApprove

/// M6 approval screens: the full-screen prompt for one computer request.
/// Ports Android `ui/ApproveActivity.kt` (Ask / Enrolled-code / Failed
/// phases): the phone shows service/user/host/tty/rhost/time with Approve
/// and Deny; Approve opens the biometric prompt and the phone signs only
/// after Face ID / Touch ID. Screens take state + action closures (no
/// backend); the app feeds them from `LinkRunner` approve events and
/// answers through the approval flow.
///
/// Demo fixtures mirror the `FLUX_DEMO=1` pages; release builds ignore the
/// extras. Over-lock-screen delivery is a time-sensitive notification with
/// Approve/Deny actions (see `ApproveNotifications` in `FluxFeatures`);
/// lock-screen action behavior is device-gated.

// MARK: - State

/// What the approve screen shows. Mirrors Android `Phase`.
public enum ApprovePhase: Sendable, Equatable {
    case ask(working: Bool)
    case enrolled(code: String)
    case failed(message: String)
}

// MARK: - Prompt

/// Full-screen approval prompt for one held `ApproveRequest`.
public struct ApprovePromptScreen: View {
    public var request: ApproveRequest
    public var computerName: String
    public var phase: ApprovePhase
    public var onApprove: () -> Void
    public var onDeny: () -> Void
    public var onClose: () -> Void

    public init(
        request: ApproveRequest,
        computerName: String? = nil,
        phase: ApprovePhase = .ask(working: false),
        onApprove: @escaping () -> Void = {},
        onDeny: @escaping () -> Void = {},
        onClose: @escaping () -> Void = {}
    ) {
        self.request = request
        self.computerName = computerName ?? request.computerName
        self.phase = phase
        self.onApprove = onApprove
        self.onDeny = onDeny
        self.onClose = onClose
    }

    public var body: some View {
        VStack {
            Spacer()
            switch phase {
            case .ask(let working):
                askView(working: working)
            case .enrolled(let code):
                enrolledView(code: code)
            case .failed(let message):
                failedView(message: message)
            }
            Spacer()
        }
        .padding(24)
    }

    private func askView(working: Bool) -> some View {
        VStack(spacing: 14) {
            Image(systemName: request.kind == .enroll ? "person.badge.key" : "faceid")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)
                .accessibilityLabel("Approval request")
            Text(ApproveMessage.question(request))
                .font(.headline)
                .multilineTextAlignment(.center)
            ForEach(details, id: \.self) { line in
                Text(line)
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if request.kind == .approve {
                Text("Approve only if you just typed the command.")
                    .font(.body)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button("Deny", action: onDeny)
                    .buttonStyle(.bordered)
                    .disabled(working)
                Button(request.kind == .enroll ? "Enroll" : "Approve", action: onApprove)
                    .buttonStyle(.borderedProminent)
                    .disabled(working)
            }
            .padding(.top, 8)
        }
    }

    private var details: [String] {
        if request.kind == .approve {
            var lines: [String] = []
            if !request.tty.isEmpty { lines.append("Terminal: \(request.tty)") }
            if !request.rhost.isEmpty { lines.append("From: \(request.rhost)") }
            lines.append("Asked at \(ApprovePromptScreen.timeString(request.time)) by \(computerName)")
            return lines
        }
        return ["Flux makes a key for \(computerName). Each approval then needs Face ID or Touch ID."]
    }

    private func enrolledView(code: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "person.badge.key")
                .font(.system(size: 72))
                .foregroundColor(.accentColor)
            Text("Compare the key code")
                .font(.headline)
            Text("Check that the terminal shows this code. Then type y in the terminal.")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text(code)
                .font(.system(.title2, design: .monospaced))
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(.quaternary, in: RoundedRectangle(cornerRadius: 16))
                .accessibilityLabel("Key code \(code)")
            Button("Done", action: onClose)
                .buttonStyle(.borderedProminent)
        }
    }

    private func failedView(message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 64))
                .foregroundStyle(.secondary)
            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)
            Text("The computer asks for the password.")
                .font(.body)
                .foregroundStyle(.secondary)
            Button("Close", action: onClose)
                .buttonStyle(.borderedProminent)
        }
    }

    static func timeString(_ unixSeconds: Int64) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(unixSeconds))
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}

// MARK: - Previews

#Preview("Approve ask") {
    ApprovePromptScreen(request: ApprovePromptScreen.demoRequest)
}

#Preview("Approve enrolled") {
    ApprovePromptScreen(
        request: ApprovePromptScreen.demoRequest,
        phase: .enrolled(code: "62AF 8704 764F AF8E"))
}

#Preview("Approve failed") {
    ApprovePromptScreen(
        request: ApprovePromptScreen.demoRequest,
        phase: .failed(message: ApproveMessage.biometryChangedProblem))
}

public extension ApprovePromptScreen {
    static var demoRequest: ApproveRequest {
        ApproveRequest(
            computerId: "pc1", computerName: "omarchy-xps", id: "req1", kind: .approve,
            host: "omarchy-xps", user: "alice", service: "sudo",
            tty: "/dev/pts/3", rhost: "",
            time: 1_790_000_000, nonce: ApproveMessage.testNonce, timeoutSeconds: 20)
    }
}
