import CryptoKit
import Foundation
import LocalAuthentication
import Security
import UserNotifications

/// flux.approve in both directions. A paired computer asks this Mac to
/// approve sudo, polkit, or a lock screen, or to make the key for approvals.
/// This Mac signs with its Secure Enclave key only after Touch ID, and the
/// root helper on the computer checks the signature. This Mac shows 1 request
/// at a time. docs/approve.md is the security design.
public final class ApprovePlugin: FluxPlugin, @unchecked Sendable {
    public static let notificationCategory = "approve"
    static let notificationId = "approve"

    public let incoming = [PacketType.fluxApprove]
    public let outgoing = [PacketType.fluxApprove]
    public let model: ApproveModel
    private weak var core: FluxCore?

    @MainActor private var expiry: Task<Void, Never>?
    /// The Touch ID context of the running signature. Invalidating it closes
    /// the Touch ID prompt.
    @MainActor private var context: LAContext?

    @MainActor
    public init() {
        model = ApproveModel()
    }

    /// Set in `attach`, before the network starts.
    private var keys: ApproveKeys!

    public func attach(core: FluxCore) {
        self.core = core
        let keys = ApproveKeys(directory: core.paths.data.appendingPathComponent("approve", isDirectory: true))
        self.keys = keys
        Notifier.shared.register(category: Self.notificationCategory, actions: [
            UNNotificationAction(identifier: "approve", title: "Approve", options: [.foreground]),
            UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
        ]) { [weak self] action, info, _ in
            guard let id = info["id"] as? String else { return }
            DispatchQueue.main.async { MainActor.assumeIsolated { self?.notificationAction(action, id: id) } }
        }
        DispatchQueue.main.async { MainActor.assumeIsolated { self.model.keys = keys.all() } }
    }

    /// The core lock is held. The main queue keeps the order of the packets.
    public func handle(_ packet: Packet, from device: Device) {
        let computerId = device.id
        let computerName = device.name
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.receive(packet, computerId: computerId, computerName: computerName) }
        }
    }

    // MARK: Requests

    @MainActor
    func receive(_ p: Packet, computerId: String, computerName: String) {
        switch p.string("kind") {
        case "cancel":
            if let id = p.string("id") { end(id, .cancelled) }
        case "request", "enroll":
            open(p, computerId: computerId, computerName: computerName)
        default:
            break
        }
    }

    @MainActor
    private func open(_ p: Packet, computerId: String, computerName: String) {
        guard let id = p.string("id") else { return }
        let r = ApproveMessage.parse(p, computerId: computerId, computerName: computerName)
        if let r, model.current?.id == r.id {
            model.present?()
            return
        }
        let problem: String?
        if let r {
            if !ApproveMessage.fresh(r, now: Int64(Date().timeIntervalSince1970)) {
                problem = "The clocks of this Mac and the computer differ by more than 10 minutes"
            } else if r.kind == .approve && !keys.has(computerId) {
                problem = "This Mac has no key for the computer. Run: sudo flux approve enroll"
            } else if model.current != nil {
                problem = "Another request is open on this Mac"
            } else {
                problem = nil
            }
        } else {
            problem = "The request is not valid"
        }
        if let problem {
            FluxLog.plugin.info("approve: refused a request from \(computerName, privacy: .public): \(problem, privacy: .public)")
            core?.send(ApproveMessage.failed(id, message: problem), to: computerId)
            model.record(ApproveRecord(requestId: id, computerId: computerId, kind: r?.kind ?? (p.string("kind") == "enroll" ? .enroll : .approve),
                                       summary: r.map(ApproveMessage.question) ?? "A request that is not valid",
                                       received: Date(), outcome: .refused(problem)))
            return
        }
        guard let r else { return }
        model.current = r
        model.shown = r
        model.phase = .ask
        model.deadline = Date().addingTimeInterval(TimeInterval(r.timeoutSeconds))
        model.record(ApproveRecord(requestId: r.id, computerId: computerId, kind: r.kind, summary: ApproveMessage.question(r),
                                   received: Date(), outcome: .open))
        // The computer stops waiting at its timeout, so the request ends too.
        expiry = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(r.timeoutSeconds))
            if !Task.isCancelled { self?.end(r.id, .expired) }
        }
        Notifier.shared.post(id: Self.notificationId, category: Self.notificationCategory,
                             title: r.kind == .approve ? "Approve \(r.service) on \(r.host)?" : "Enroll this Mac on \(r.host)?",
                             body: ([ApproveMessage.question(r)] + Self.details(r)).joined(separator: "\n"),
                             userInfo: ["id": r.id])
        model.present?()
    }

    /// The lines under the question: the terminal, the remote host, and who asks.
    public static func details(_ r: ApproveRequest) -> [String] {
        switch r.kind {
        case .approve:
            var lines: [String] = []
            if !r.tty.isEmpty { lines.append("Terminal: \(r.tty)") }
            if !r.rhost.isEmpty { lines.append("From: \(r.rhost)") }
            let time = Date(timeIntervalSince1970: TimeInterval(r.time)).formatted(date: .omitted, time: .standard)
            lines.append("Asked at \(time) by \(r.computerName)")
            return lines
        case .enroll:
            return ["Flux makes a key for \(r.computerName) in the Secure Enclave of this Mac. Each approval then needs Touch ID."]
        }
    }

    // MARK: Actions

    /// Asks for Touch ID, signs the open request, and sends the signature.
    /// For an enrollment, it first makes a new key.
    @MainActor
    public func approve() {
        guard let r = model.current, model.phase == .ask else { return }
        if let problem = Self.biometryProblem() {
            fail(r, problem)
            return
        }
        if r.kind == .approve && keys.biometryChanged(computerId: r.computerId) {
            keys.delete(r.computerId)
            model.keys = keys.all()
            fail(r, "The fingerprints on this Mac changed. Enroll again with: sudo flux approve enroll")
            return
        }
        model.phase = .working
        let c = LAContext()
        c.localizedReason = r.kind == .approve
            ? "approve \(r.service) for \(r.user) on \(r.host)"
            : "enroll this Mac to approve sudo for \(r.user) on \(r.host)"
        c.localizedFallbackTitle = ""
        c.touchIDAuthenticationAllowableReuseDuration = 0
        context = c
        let job = SignJob(request: r, keys: keys, context: c)
        Task.detached {
            let result = Result { try job.run() }
            await MainActor.run { self.signed(r, result) }
        }
    }

    /// Denies the open request.
    @MainActor
    public func deny() {
        guard let r = model.current else { return }
        core?.send(ApproveMessage.denied(r.id), to: r.computerId)
        end(r.id, .denied)
    }

    /// Closes the result of an enrollment or a failure.
    @MainActor
    public func closeResult() {
        guard model.current == nil else { return }
        model.shown = nil
        model.phase = .ask
    }

    /// Deletes the key of the computer. The key file on the computer stays
    /// until `sudo flux approve remove`.
    @MainActor
    public func removeKey(_ computerId: String) {
        keys.delete(computerId)
        model.keys = keys.all()
    }

    @MainActor
    private func notificationAction(_ action: String, id: String) {
        guard model.current?.id == id else { return }
        switch action {
        case "approve":
            model.present?()
            approve()
        case "deny":
            deny()
        default:
            model.present?()
        }
    }

    @MainActor
    private func signed(_ r: ApproveRequest, _ result: Result<Signed, Error>) {
        context = nil
        // The request ended while Touch ID ran: the answer is too late.
        guard model.current?.id == r.id else { return }
        switch result {
        case .success(let s):
            if let key = s.newKey {
                do {
                    try keys.save(blob: key.blob, publicKey: key.publicKey, computerId: r.computerId, host: r.host, user: r.user)
                } catch {
                    FluxLog.plugin.error("approve: saving the key failed: \(String(describing: error), privacy: .public)")
                    fail(r, "This Mac could not save its approval key.")
                    return
                }
                model.keys = keys.all()
                guard core?.send(ApproveMessage.enrolled(r.id, spki: key.publicKey, signature: s.signature), to: r.computerId) == true else {
                    fail(r, "The computer is not connected. Run the enrollment again.")
                    return
                }
                model.phase = .enrolled(code: ApproveMessage.fingerprint(key.publicKey))
                end(r.id, .enrolled)
            } else {
                guard core?.send(ApproveMessage.approved(r.id, signature: s.signature), to: r.computerId) == true else {
                    fail(r, "The computer is not connected.")
                    return
                }
                end(r.id, .approved)
            }
        case .failure(let error):
            if Self.isCancel(error) {
                model.phase = .ask
                return
            }
            FluxLog.plugin.error("approve: signing failed: \(String(describing: error), privacy: .public)")
            fail(r, Self.message(for: error, kind: r.kind))
        }
    }

    @MainActor
    private func fail(_ r: ApproveRequest, _ message: String) {
        core?.send(ApproveMessage.failed(r.id, message: message), to: r.computerId)
        model.phase = .failed(message)
        end(r.id, .failed(message))
    }

    /// Ends the request `id`: it closes the notification, the Touch ID prompt,
    /// and the prompt, unless the prompt shows a result.
    @MainActor
    private func end(_ id: String, _ outcome: ApproveOutcome) {
        guard model.current?.id == id else { return }
        model.current = nil
        model.deadline = nil
        expiry?.cancel()
        expiry = nil
        context?.invalidate()
        context = nil
        Notifier.shared.remove(id: Self.notificationId)
        model.resolve(id, outcome)
        if model.phase == .ask || model.phase == .working {
            model.shown = nil
            model.phase = .ask
        }
    }

    // MARK: Touch ID

    /// Why this Mac cannot use Touch ID now, or nil.
    public static func biometryProblem() -> String? {
        let c = LAContext()
        var error: NSError?
        if c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return nil }
        switch error.flatMap({ LAError.Code(rawValue: $0.code) }) {
        case .biometryNotEnrolled: return "Set up Touch ID in System Settings first."
        case .biometryLockout: return "Touch ID is locked. Unlock this Mac with the password first."
        default: return "Touch ID is not available. Open the lid of this Mac, or connect a keyboard with Touch ID."
        }
    }

    private static func isCancel(_ error: Error) -> Bool {
        let e = error as NSError
        if e.domain == LAErrorDomain {
            return [LAError.userCancel, .systemCancel, .appCancel, .userFallback].map(\.rawValue).contains(e.code)
        }
        return e.domain == NSOSStatusErrorDomain && e.code == Int(errSecUserCanceled)
    }

    private static func message(for error: Error, kind: ApproveRequest.Kind) -> String {
        let e = error as NSError
        if e.domain == LAErrorDomain {
            switch LAError.Code(rawValue: e.code) {
            case .biometryLockout: return "Touch ID is locked. Unlock this Mac with the password first."
            case .biometryNotAvailable, .biometryNotEnrolled: return biometryProblem() ?? "Touch ID is not available."
            case .authenticationFailed: return "Touch ID did not recognize the fingerprint."
            default: break
            }
        }
        if e.domain == NSOSStatusErrorDomain && e.code == Int(errSecInteractionNotAllowed) {
            return "This Mac is locked, so it cannot use its approval key."
        }
        return kind == .enroll ? "This Mac could not make its approval key." : "This Mac could not use its approval key."
    }
}

/// The result of 1 signature.
private struct Signed: Sendable {
    struct NewKey: Sendable {
        /// The Secure Enclave blob of the private key.
        var blob: Data
        /// The public key in DER.
        var publicKey: Data
    }

    /// The ASN.1 DER signature.
    var signature: Data
    /// The key that an enrollment made.
    var newKey: NewKey?
}

/// 1 signature off the main thread. The Secure Enclave blocks while Touch ID
/// runs.
private struct SignJob: @unchecked Sendable {
    let request: ApproveRequest
    let keys: ApproveKeys
    /// LAContext is not Sendable. Only this job and `invalidate` use it.
    let context: LAContext

    func run() throws -> Signed {
        switch request.kind {
        case .approve:
            let key = try keys.signer(computerId: request.computerId, context: context)
            return Signed(signature: try key.signature(for: ApproveMessage.approval(request)).derRepresentation)
        case .enroll:
            let key = try ApproveKeys.create(context: context)
            let spki = key.publicKey.derRepresentation
            let signature = try key.signature(for: ApproveMessage.enrollment(request, spki: spki)).derRepresentation
            return Signed(signature: signature, newKey: .init(blob: key.dataRepresentation, publicKey: spki))
        }
    }
}
