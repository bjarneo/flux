import Foundation
import FluxProto
import FluxApprove
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(Security)
import Security
#endif

/// Production approval decider (D19/D20): UI-mediated biometric signing.
///
/// `LinkRunner` calls `decide(_:)` off the session thread (it may block);
/// the app shows the prompt and answers through `resolve(id:accept:)`.
/// Approve taps run Face ID / Touch ID + Secure Enclave signing here;
/// every failure becomes a `failed` packet — a bad signature is never
/// sent (fail closed, like the `FluxTestPeer` test signer this mirrors).
///
/// Stale answers are safe: `LinkRunner` drops replies for closed prompts
/// by id, and request ids are unique per prompt.
public final class ApproveFlow: @unchecked Sendable {
    private let approvals = PairApproval()
    private let authenticate: (String) -> AuthResult
    private let lock = NSLock()
    private nonisolated(unsafe) var pending: [String: ApproveRequest] = [:]
    private nonisolated(unsafe) var enrolledCodes: [String: String] = [:]
    /// Answered-prompt replies, for the UI's `.failed` phase. Read-once
    /// (see `failureMessage`); bounded so answered prompts leave no residue.
    private nonisolated(unsafe) var replies: [String: Packet] = [:]
    /// Diagnostic sink (the app prints + shows these on the status line).
    /// Auth/sign failures log the OS error code here — the wire message
    /// stays user-actionable, but device runs need the code to tell a
    /// misread from an invalidated key (D20).
    public var onLog: (@Sendable (String) -> Void)?

    public init() {
        self.authenticate = Self.systemAuthenticate
    }

    /// Test seam: drives biometric outcomes without a finger.
    init(authenticate: @escaping (String) -> AuthResult) {
        self.authenticate = authenticate
    }

    /// The decider for `LinkRunner.Configuration.approveDecider`. Blocks
    /// until the UI resolves the prompt (or its timeout); returns the
    /// reply packet, or nil to keep waiting (dropped if stale).
    public func decide(_ r: ApproveRequest) -> Packet? {
        lock.withLock { pending[r.id] = r }
        defer { lock.withLock { pending.removeValue(forKey: r.id) } }
        guard let accept = approvals.decide(peerId: r.id, timeout: TimeInterval(r.timeoutSeconds)) else { return nil }
        guard accept else { return storeReply(id: r.id, packet: ApproveMessage.denied(id: r.id)) }
        return storeReply(id: r.id, packet: answer(r))
    }

    /// Resolves a waiting prompt from the UI (Accept/Deny/close).
    /// Verdicts for prompts that are not open are ignored: a late
    /// Close/Deny after an answer must neither linger (a kept verdict
    /// could pre-answer a later prompt) nor answer anything (`LinkRunner`
    /// drops stale replies by id anyway).
    public func resolve(id: String, accept: Bool) {
        guard lock.withLock({ pending[id] }) != nil else { return }
        approvals.resolve(peerId: id, accept: accept)
    }

    /// The held request for the prompt UI. Waits briefly: `LinkRunner`
    /// emits the prompt event before the decider thread stores the
    /// request, so an immediate read can miss. Returns nil when truly gone.
    public func pendingRequest(id: String) -> ApproveRequest? {
        for _ in 0..<10 {
            if let r = lock.withLock({ pending[id] }) { return r }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return lock.withLock { pending[id] }
    }

    /// Key code shown after a successful enrollment (compare with the
    /// desktop's `flux approve enroll` output before typing `y`).
    public func enrolledCode(computerId: String) -> String? {
        lock.withLock { enrolledCodes[computerId] }
    }

    /// The `failed` packet's message for an answered prompt — the UI shows
    /// it in the `.failed` phase, notably the enroll-again guidance after
    /// a biometric enrollment change (D20). Consumed on read, so answered
    /// prompts leave no residue; nil for denies/approvals (no `error`
    /// field) and for prompts that never answered.
    public func failureMessage(id: String) -> String? {
        lock.withLock { replies.removeValue(forKey: id) }.flatMap { $0.string("error") }
    }

    private func storeReply(id: String, packet: Packet?) -> Packet? {
        lock.withLock {
            if let packet {
                if replies.count > 16, let oldest = replies.keys.first {
                    replies.removeValue(forKey: oldest)
                }
                replies[id] = packet
            }
        }
        return packet
    }

    // MARK: - Answering (test-signer mirror, production keys + biometrics)

    private func answer(_ r: ApproveRequest) -> Packet? {
        switch r.kind {
        case .enroll:
            return answerEnroll(r)
        case .approve:
            return answerApprove(r)
        }
    }

    private func answerEnroll(_ r: ApproveRequest) -> Packet {
        do {
            let spki = try ApproveKeys.create(computerId: r.computerId)
            switch authenticate("Enroll this phone to approve \(r.service) for \(r.user) on \(r.host)") {
            case .cancelled:
                ApproveKeys.delete(computerId: r.computerId)
                return ApproveMessage.denied(id: r.id)
            case .failed(let message):
                log("enroll auth failed id=\(r.id): \(message)")
                ApproveKeys.delete(computerId: r.computerId)
                return ApproveMessage.failed(id: r.id, message: message)
            case .biometryGone:
                log("enroll auth id=\(r.id): biometry gone")
                // No biometrics to auth with: the half-made key can never
                // be used. Enrollment needs biometrics, full stop.
                ApproveKeys.delete(computerId: r.computerId)
                return ApproveMessage.failed(id: r.id, message: ApproveMessage.noBiometricProblem)
            case .lockedOut:
                log("enroll auth id=\(r.id): locked out")
                ApproveKeys.delete(computerId: r.computerId)
                return ApproveMessage.failed(id: r.id, message: ApproveMessage.biometryLockoutProblem)
            case .ok(let context):
                let msg = try ApproveMessage.enrollment(
                    host: r.host, user: r.user, spki: spki, time: r.time, nonce: r.nonce)
                let sig = try ApproveKeys.sign(message: msg, computerId: r.computerId, context: context)
                // Self-check before sending the pubkey: never emit a signature
                // the desktop would reject (plan §4.12).
                guard ApproveKeys.verify(signature: sig, message: msg, spki: spki) else {
                    ApproveKeys.delete(computerId: r.computerId)
                    return ApproveMessage.failed(id: r.id, message: ApproveMessage.signProblem)
                }
                let code = ApproveMessage.fingerprint(spki)
                lock.withLock { enrolledCodes[r.computerId] = code }
                return ApproveMessage.enrolled(id: r.id, spki: spki, signature: sig)
            }
        } catch let e as ApproveKeys.KeyError {
            log("enroll key id=\(r.id): \(e)")
            return enrollError(id: r.id, computerId: r.computerId, error: e)
        } catch {
            log("enroll unexpected id=\(r.id): \(error)")
            return ApproveMessage.failed(id: r.id, message: ApproveMessage.keyUnusableProblem)
        }
    }

    private func answerApprove(_ r: ApproveRequest) -> Packet {
        do {
            let msg = try ApproveMessage.approval(
                host: r.host, user: r.user, service: r.service,
                tty: r.tty, rhost: r.rhost, time: r.time, nonce: r.nonce)
            guard ApproveKeys.has(computerId: r.computerId) else {
                return ApproveMessage.failed(id: r.id, message: ApproveMessage.noKeyProblem)
            }
            switch authenticate("Approve \(r.service) for \(r.user) on \(r.host)") {
            case .cancelled:
                return ApproveMessage.denied(id: r.id)
            case .failed(let message):
                log("approve auth failed id=\(r.id): \(message)")
                return ApproveMessage.failed(id: r.id, message: message)
            case .biometryGone:
                log("approve auth id=\(r.id): biometry gone")
                // The no-key pre-check above guarantees a key exists: with
                // no usable biometrics a `biometryCurrentSet` key is dead
                // (new enrollment invalidates it, removing every
                // enrollment does too — D20), so delete it and point at
                // re-enrollment.
                ApproveKeys.delete(computerId: r.computerId)
                return ApproveMessage.failed(id: r.id, message: ApproveMessage.biometryChangedProblem)
            case .lockedOut:
                log("approve auth id=\(r.id): locked out")
                // Passcode unlock re-arms biometrics; the key is intact.
                return ApproveMessage.failed(id: r.id, message: ApproveMessage.biometryLockoutProblem)
            case .ok(let context):
                let sig = try ApproveKeys.sign(message: msg, computerId: r.computerId, context: context)
                return ApproveMessage.approved(id: r.id, signature: sig)
            }
        } catch let e as ApproveKeys.KeyError {
            log("approve sign id=\(r.id): \(e)")
            switch e {
            case .noKey:
                return ApproveMessage.failed(id: r.id, message: ApproveMessage.noKeyProblem)
            case .biometryChanged:
                ApproveKeys.delete(computerId: r.computerId)
                return ApproveMessage.failed(id: r.id, message: ApproveMessage.biometryChangedProblem)
            case .authCancelled:
                return ApproveMessage.denied(id: r.id)
            case .failed, .unavailable:
                return ApproveMessage.failed(id: r.id, message: ApproveMessage.signProblem)
            }
        } catch {
            log("approve unexpected id=\(r.id): \(error)")
            return ApproveMessage.failed(id: r.id, message: ApproveMessage.signProblem)
        }
    }

    private func enrollError(id: String, computerId: String, error: ApproveKeys.KeyError) -> Packet {
        switch error {
        case .noKey, .failed, .unavailable:
            ApproveKeys.delete(computerId: computerId)
            return ApproveMessage.failed(id: id, message: ApproveMessage.keyUnusableProblem)
        case .biometryChanged:
            ApproveKeys.delete(computerId: computerId)
            return ApproveMessage.failed(id: id, message: ApproveMessage.biometryChangedProblem)
        case .authCancelled:
            ApproveKeys.delete(computerId: computerId)
            return ApproveMessage.denied(id: id)
        }
    }

    // MARK: - Biometrics

    /// Diagnostic sink writer (see `onLog`).
    private func log(_ message: String) {
        onLog?(message)
    }

    /// Per-use biometric auth outcome. Runs on the decider thread, never
    /// the UI thread. Every non-ok outcome fails closed on the desktop
    /// (password fallback); they differ only in messaging and key handling.
    enum AuthResult {
        case ok(Any)
        case cancelled
        case failed(String)
        /// No biometrics to auth with (none enrolled, none available, or
        /// the enrolled set changed shape): a `biometryCurrentSet` key is
        /// dead, delete it and answer enroll-again (D20).
        case biometryGone
        /// Too many attempts: iOS needs the device passcode before
        /// biometrics work again. The key is intact.
        case lockedOut
    }

    private static func systemAuthenticate(reason: String) -> AuthResult {
#if canImport(LocalAuthentication)
        let context = LAContext()
        var evalError: NSError?
        guard context.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: &evalError) else {
            return mapAuthError(evalError)
        }
        let sema = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var result: AuthResult = .failed(ApproveMessage.signProblem)
        context.evaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, localizedReason: reason) { success, error in
            if success {
                result = .ok(context)
            } else {
                result = mapAuthError(error)
            }
            sema.signal()
        }
        sema.wait()
        return result
#else
        return .failed(ApproveMessage.noBiometricProblem)
#endif
    }

#if canImport(LocalAuthentication)
    /// Maps an `LAContext` failure to an auth outcome. Internal for the
    /// mapping unit test (codes are constructed `NSError`s, no finger).
    static func mapAuthError(_ error: Error?) -> AuthResult {
        switch (error as NSError?)?.code {
        case LAError.userCancel.rawValue,
            LAError.systemCancel.rawValue,
            LAError.appCancel.rawValue,
            // "Enter Password" on the biometric dialog: the user chose the
            // password path, which is a decline, not a failure.
            LAError.userFallback.rawValue:
            return .cancelled
        case LAError.biometryNotEnrolled.rawValue,
            LAError.biometryNotAvailable.rawValue:
            return .biometryGone
        case LAError.biometryLockout.rawValue:
            return .lockedOut
        default:
            // One attempt misread (finger moved, partial touch) or any
            // other auth failure (invalidated context, system cancel,
            // unknown cause): also a retry, key kept. Only a proven-dead
            // key (`biometryGone`, sign-time `errSecAuthFailed`) is ever
            // deleted; everything else fails closed to the password with
            // the code in the device log (`onLog`) for diagnosis.
            return .failed(ApproveMessage.biometryRetryProblem)
        }
    }
#endif
}
