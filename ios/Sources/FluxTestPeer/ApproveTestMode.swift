import Foundation
import FluxProto
import FluxApprove
#if canImport(Darwin)
import Darwin
#endif

/// Test-mode approval answering for `FluxTestPeer --exercise-m6`.
///
/// Signs with NON-BIOMETRIC keys (`ApproveKeys.createTestKey`) under the
/// production alias scheme — the biometric gate is device-enforced at
/// signing time and cannot be exercised from this CLI harness, so every
/// reply is logged `TEST MODE (no biometric)`. The wire (parse, exact
/// message bytes, DER signatures, enroll/approve/deny/timeout/cancel) is
/// fully real: the desktop verifies each signature with openssl against
/// the enrolled pubkey.
///
/// - Ephemeral runs hold keys in memory (`stored=false`): zero Keychain
///   residue, no cleanup needed.
/// - `--persist` stores Keychain items (`stored=true`), tracked in the
///   enrolled-computer index so `--forget` removes them.
final class TestApproveSigner: @unchecked Sendable {
    private let stored: Bool
    private let deny: Bool
    private let delaySeconds: UInt32

    /// - `stored`: persist keys in the Keychain (`--persist`) or hold them
    ///   in memory (ephemeral runs).
    /// - `deny`: deny approvals with `denied` (`--approve-deny`).
    ///   Enrollments are still approved (deny targets the login prompt).
    /// - `delaySeconds`: wait before deciding (`--approve-delay`), so the
    ///   harness can cancel/timeout the prompt first. Late answers are
    ///   dropped by id, never sent.
    init(stored: Bool, deny: Bool, delaySeconds: UInt32 = 0) {
        self.stored = stored
        self.deny = deny
        self.delaySeconds = delaySeconds
    }

    /// Answers one held request. Never throws: failures become `failed`
    /// packets (fail closed — a bad signature is never sent).
    func decide(_ r: ApproveRequest) -> Packet? {
#if canImport(Darwin)
        if delaySeconds > 0 { sleep(delaySeconds) }
#endif
        if deny, r.kind == .approve {
            testLog("APPROVE DENY id=\(r.id) (TEST MODE)")
            return ApproveMessage.denied(id: r.id)
        }
        switch r.kind {
        case .enroll:
            return answerEnroll(r)
        case .approve:
            return answerApprove(r)
        }
    }

    private func answerEnroll(_ r: ApproveRequest) -> Packet {
        do {
            let spki = try ApproveKeys.createTestKey(computerId: r.computerId, stored: stored)
            let msg = try ApproveMessage.enrollment(
                host: r.host, user: r.user, spki: spki, time: r.time, nonce: r.nonce)
            let sig = try ApproveKeys.sign(message: msg, computerId: r.computerId)
            // Self-check before sending the pubkey: never emit a signature
            // the desktop would reject (plan §4.12).
            guard ApproveKeys.verify(signature: sig, message: msg, spki: spki) else {
                testLog("APPROVE ENROLL self-check FAILED id=\(r.id)")
                return ApproveMessage.failed(id: r.id, message: ApproveMessage.signProblem)
            }
            testLog("APPROVE ENROLL id=\(r.id) key=\(ApproveMessage.fingerprint(spki)) (TEST MODE, no biometric)")
            return ApproveMessage.enrolled(id: r.id, spki: spki, signature: sig)
        } catch {
            testLog("APPROVE ENROLL error id=\(r.id): \(error)")
            return ApproveMessage.failed(id: r.id, message: ApproveMessage.keyUnusableProblem)
        }
    }

    private func answerApprove(_ r: ApproveRequest) -> Packet {
        do {
            let msg = try ApproveMessage.approval(
                host: r.host, user: r.user, service: r.service,
                tty: r.tty, rhost: r.rhost, time: r.time, nonce: r.nonce)
            let sig = try ApproveKeys.sign(message: msg, computerId: r.computerId)
            testLog("APPROVE SIGN id=\(r.id) service=\(r.service) (TEST MODE, no biometric)")
            return ApproveMessage.approved(id: r.id, signature: sig)
        } catch let e as ApproveKeys.KeyError {
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
            return ApproveMessage.failed(id: r.id, message: ApproveMessage.signProblem)
        }
    }
}

private func testLog(_ s: String) {
    print("flux-test-peer: \(s)")
#if canImport(Darwin)
    fflush(stdout)
#endif
}
