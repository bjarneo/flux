import Foundation
import FluxProto

/// The approval/enrollment requests waiting on this phone. Port of Android
/// `core/Approvals.kt` (`onPacket`/`receive`/`clear`, minus the Android
/// notification/activity calls — the link and the UI own those).
///
/// Rules (from Android + Go `handleApprove`):
/// - One request at a time: a second id gets a `busy` failure.
/// - A rule-breaking packet gets an `invalid` failure (needs its id).
/// - A stale time gets a `clock-skew` failure.
/// - An approval with no enrolled key gets the `enroll again` failure.
/// - A `cancel` with the open id closes it silently.
/// - The computer stops waiting at the request timeout, so the phone
///   closes it locally too (`expire`).
///
/// Pure value type with an injectable clock and key check, so the whole
/// matrix is unit-testable without biometrics or sockets.
public struct ApprovalsStore: Sendable {
    /// The request on screen, if any.
    public private(set) var current: ApproveRequest?
    /// When `current` closes locally (received time + timeout).
    private var deadline: Int64 = 0

    public var nowSeconds: @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970) }
    public var hasKey: @Sendable (String) -> Bool = { _ in false }

    public init() {}

    public init(nowSeconds: @Sendable @escaping () -> Int64, hasKey: @Sendable @escaping (String) -> Bool) {
        self.nowSeconds = nowSeconds
        self.hasKey = hasKey
    }

    /// What `receive` decided: hold the request for the prompt, or answer
    /// the failure packet at once (the phone sends nothing else by itself).
    public enum Intake: Sendable, Equatable {
        case hold(ApproveRequest)
        case reply(Packet)
    }

    /// Takes a desktop→phone `flux.approve` request/enroll packet.
    /// Nil for packets with no id (nothing to answer, like Go).
    public mutating func receive(_ p: Packet, computerId: String, computerName: String) -> Intake? {
        guard let id = p.string("id"), !id.isEmpty else { return nil }
        let now = nowSeconds()
        guard let r = ApproveMessage.parse(p, computerId: computerId, computerName: computerName) else {
            return .reply(ApproveMessage.failed(id: id, message: ApproveMessage.invalidRequest))
        }
        let problem: String? = {
            if !ApproveMessage.fresh(r, nowSeconds: now) { return ApproveMessage.clockSkewProblem }
            if r.kind == .approve, !hasKey(computerId) { return ApproveMessage.noKeyProblem }
            if let open = current, open.id != r.id { return ApproveMessage.busyProblem }
            return nil
        }()
        if let problem {
            return .reply(ApproveMessage.failed(id: id, message: problem))
        }
        current = r
        deadline = now + Int64(r.timeoutSeconds)
        return .hold(r)
    }

    /// Closes the open request with `id` (desktop `cancel`, or the local
    /// answer/timeout path). True when something closed.
    @discardableResult
    public mutating func cancel(id: String) -> Bool {
        guard current?.id == id else { return false }
        current = nil
        return true
    }

    /// Alias for `cancel` after the phone answers (approve/deny/error sent).
    @discardableResult
    public mutating func resolve(id: String) -> Bool {
        cancel(id: id)
    }

    /// Closes the open request when its timeout passed. Returns it so the
    /// caller can log/emit the expiry (the phone sends no packet: `fluxd`
    /// already cancelled on its own timeout).
    @discardableResult
    public mutating func expire() -> ApproveRequest? {
        guard let open = current, nowSeconds() >= deadline else { return nil }
        current = nil
        return open
    }
}
