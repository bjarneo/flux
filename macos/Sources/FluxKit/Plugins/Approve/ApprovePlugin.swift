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
        do {
            try keys.excludeFromBackup()
        } catch {
            FluxLog.plugin.error("approve keys stay in backups: \(String(describing: error), privacy: .public)")
        }
        Notifier.shared.register(category: Self.notificationCategory, actions: Self.notificationActions(platform: .current)) { [weak self] action, info, _ in
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
        let texts = ApproveTexts.current
        #if os(iOS)
        let secureEnclave = Self.secureEnclaveAvailable
        #else
        // A Mac without a Secure Enclave has no Touch ID either, and Approve
        // says so.
        let secureEnclave = true
        #endif
        if let problem = Self.refusal(r, now: Int64(Date().timeIntervalSince1970), hasKey: keys.has(computerId),
                                      busy: model.current != nil, secureEnclave: secureEnclave, texts: texts) {
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
                             title: r.kind == .approve ? "Approve \(r.service) on \(r.host)?" : texts.enrollTitle(host: r.host),
                             body: ([ApproveMessage.question(r)] + Self.details(r)).joined(separator: "\n"),
                             userInfo: ["id": r.id], interruptionLevel: Self.interruptionLevel)
        model.present?()
    }

    /// Why this device refuses the request without asking the user, or nil.
    /// `r` is nil for a request that is not valid.
    static func refusal(_ r: ApproveRequest?, now: Int64, hasKey: Bool, busy: Bool, secureEnclave: Bool, texts: ApproveTexts) -> String? {
        guard let r else { return "The request is not valid" }
        if !secureEnclave { return texts.noSecureEnclave }
        if !ApproveMessage.fresh(r, now: now) { return texts.clockSkew }
        if r.kind == .approve && !hasKey { return texts.noKey }
        if busy { return texts.anotherOpen }
        return nil
    }

    /// An iPhone asks for the time-sensitive level, which goes through a
    /// Focus only when the app has the time-sensitive entitlement; the
    /// project does not set it, see docs/ios.md. The Mac keeps the default level.
    private static var interruptionLevel: UNNotificationInterruptionLevel {
        FluxPlatform.current == .phone ? .timeSensitive : .active
    }

    /// The actions of the notification. On an iPhone, Approve needs the
    /// iPhone unlocked and opens the prompt. Deny works on the lock screen.
    static func notificationActions(platform: FluxPlatform) -> [UNNotificationAction] {
        let approve: UNNotificationActionOptions = platform == .phone ? [.foreground, .authenticationRequired] : [.foreground]
        return [
            UNNotificationAction(identifier: "approve", title: "Approve", options: approve),
            UNNotificationAction(identifier: "deny", title: "Deny", options: [.destructive]),
        ]
    }

    /// What a notification action does.
    enum NotificationRoute: Equatable {
        /// Shows the prompt.
        case present
        /// Shows the prompt and asks for the biometry at once.
        case approve
        case deny
    }

    /// The Mac asks for Touch ID right after Approve. An iPhone opens the
    /// prompt, because Face ID needs Flux on the screen, and the Approve
    /// button of the prompt asks for it.
    static func notificationRoute(_ action: String, platform: FluxPlatform) -> NotificationRoute {
        switch action {
        case "approve": return platform == .mac ? .approve : .present
        case "deny": return .deny
        default: return .present
        }
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
            return [ApproveTexts.current.enrollDetail(computer: r.computerName)]
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
        let texts = ApproveTexts.current
        if r.kind == .approve && keys.biometryChanged(computerId: r.computerId) {
            keys.delete(r.computerId)
            model.keys = keys.all()
            fail(r, texts.biometryChanged)
            return
        }
        model.phase = .working
        let c = LAContext()
        c.localizedReason = r.kind == .approve
            ? "approve \(r.service) for \(r.user) on \(r.host)"
            : texts.enrollReason(user: r.user, host: r.host)
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
    /// until `sudo flux-cli approve remove`.
    @MainActor
    public func removeKey(_ computerId: String) {
        keys.delete(computerId)
        model.keys = keys.all()
    }

    @MainActor
    private func notificationAction(_ action: String, id: String) {
        guard model.current?.id == id else { return }
        switch Self.notificationRoute(action, platform: .current) {
        case .approve:
            model.present?()
            approve()
        case .deny:
            deny()
        case .present:
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
                    fail(r, ApproveTexts.current.saveFailed)
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

    /// Whether this device can approve: it needs a Secure Enclave and the
    /// biometry. It never falls back to a key outside the Secure Enclave.
    public static func availability() -> ApproveAvailability {
        availability(secureEnclave: secureEnclaveAvailable, biometryProblem: biometryProblem(), texts: .current)
    }

    /// Whether this device can make a Secure Enclave key that needs the
    /// biometry. The iOS simulator reports a Secure Enclave, but it refuses
    /// such a key with "This call is not supported on iOS Simulator".
    static var secureEnclaveAvailable: Bool {
        #if targetEnvironment(simulator)
        false
        #else
        SecureEnclave.isAvailable
        #endif
    }

    static func availability(secureEnclave: Bool, biometryProblem: String?, texts: ApproveTexts) -> ApproveAvailability {
        if !secureEnclave { return .noSecureEnclave(texts.noSecureEnclave) }
        if let biometryProblem { return .biometry(biometryProblem) }
        return .ready
    }

    /// Why this device cannot use Touch ID or Face ID now, or nil.
    public static func biometryProblem() -> String? {
        let c = LAContext()
        var error: NSError?
        if c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &error) { return nil }
        let texts = ApproveTexts.current
        switch error.flatMap({ LAError.Code(rawValue: $0.code) }) {
        case .biometryNotEnrolled: return texts.notEnrolled
        case .biometryLockout: return texts.lockedOut
        default: return texts.unavailable
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
        let texts = ApproveTexts.current
        if e.domain == LAErrorDomain {
            switch LAError.Code(rawValue: e.code) {
            case .biometryLockout: return texts.lockedOut
            case .biometryNotAvailable, .biometryNotEnrolled: return biometryProblem() ?? texts.unavailableShort
            case .authenticationFailed: return texts.notRecognized
            default: break
            }
        }
        if e.domain == NSOSStatusErrorDomain && e.code == Int(errSecInteractionNotAllowed) {
            return texts.deviceLocked
        }
        return kind == .enroll ? texts.makeFailed : texts.useFailed
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
