import Foundation
import FluxProto

/// One approval or enrollment request from a computer (desktop→phone).
/// Port of Android `core/ApproveMessage.kt` `ApproveRequest`; the packet
/// shapes come from Go `internal/core/approve.go`
/// (`ApproveRequest`/`ApproveEnroll` bodies) and the signed bytes from
/// `docs/approve.md` (see `ApproveMessage.swift`).
public struct ApproveRequest: Sendable, Equatable {
    public enum Kind: String, Sendable {
        /// `{"kind":"request",...}` — approve a login with a fingerprint.
        case approve
        /// `{"kind":"enroll",...}` — make the key for approvals.
        case enroll
    }

    public var computerId: String
    public var computerName: String
    public var id: String
    public var kind: Kind
    public var host: String
    public var user: String
    /// PAM service (`sudo`, `polkit-1`, …). Empty for enrollments.
    public var service: String
    public var tty: String
    public var rhost: String
    /// Unix time in seconds when the computer made the request.
    public var time: Int64
    /// 32 random bytes as 64 lowercase hex digits.
    public var nonce: String
    /// How long the computer waits, clamped to 5…120 s (default 20).
    public var timeoutSeconds: Int

    public init(
        computerId: String, computerName: String, id: String, kind: Kind,
        host: String, user: String, service: String, tty: String, rhost: String,
        time: Int64, nonce: String, timeoutSeconds: Int
    ) {
        self.computerId = computerId
        self.computerName = computerName
        self.id = id
        self.kind = kind
        self.host = host
        self.user = user
        self.service = service
        self.tty = tty
        self.rhost = rhost
        self.time = time
        self.nonce = nonce
        self.timeoutSeconds = timeoutSeconds
    }
}

public extension ApproveMessage {
    // MARK: - Request timeouts (Go `approveMinTimeout/Default/Max`, Android `coerceIn`)

    /// The wait the computer reports when it sends no timeout.
    static let defaultTimeout = 20
    static let minTimeout = 5
    static let maxTimeout = 120

    // MARK: - Phone refusal strings (Android `Approvals` + `ApproveActivity`)

    /// The packet broke a field rule.
    static let invalidRequest = "The request is not valid"
    /// The signed time is more than 10 minutes from the phone clock.
    static let clockSkewProblem = "The clocks of the phone and the computer differ by more than 10 minutes"
    /// An approval arrived with no enrolled key for the computer.
    static let noKeyProblem = "This phone has no key for the computer. Run: sudo flux approve enroll"
    /// A second request arrived while one is open.
    static let busyProblem = "Another request is open on the phone"
    /// The phone has no strong biometric enrolled.
    static let noBiometricProblem = "Set up Face ID or Touch ID in the phone settings first."
    /// A new biometric invalidated the key (Android `KeyPermanentlyInvalidatedException` path).
    static let biometryChangedProblem = "The biometrics on the phone changed. Enroll again with: sudo flux approve enroll"
    /// Biometric lockout: too many failed attempts, the key is intact but
    /// iOS needs the device passcode before biometrics work again. Kept
    /// separate from `signProblem` so the desktop tells the user what to do.
    static let biometryLockoutProblem = "Too many biometric attempts. Unlock the phone with the passcode, then try again."
    /// One biometric attempt failed (misread, moved finger too fast):
    /// the key is intact, just try the request again. Kept separate from
    /// `signProblem` so a retryable misread never looks like a dead key
    /// (device finding 2026-09-27: a misread after adding a fingerprint
    /// showed the generic sign failure).
    static let biometryRetryProblem = "Face ID or Touch ID did not succeed. Try the request again."
    /// The approval key exists but cannot be used.
    static let keyUnusableProblem = "The phone could not use its approval key."
    /// Signing failed after biometric auth.
    static let signProblem = "The phone could not sign the request."

    // MARK: - Parsing (desktop→phone)

    /// Reads a `request` or an `enroll` packet. Returns nil for a packet
    /// that breaks a rule (unknown kind, bad id, missing/invalid field,
    /// bad nonce) — the caller answers `failed(id:invalidRequest)`.
    /// Port of Android `ApproveMessage.parse`.
    static func parse(_ p: Packet, computerId: String, computerName: String) -> ApproveRequest? {
        guard p.type == PacketType.fluxApprove else { return nil }
        let kind: ApproveRequest.Kind
        switch p.string("kind") {
        case "request": kind = .approve
        case "enroll": kind = .enroll
        default: return nil
        }
        guard let id = p.string("id"), !id.isEmpty, id.count <= 64, validField(id) else { return nil }
        guard let host = p.string("host"), let user = p.string("user") else { return nil }
        let service: String
        if kind == .approve {
            guard let s = p.string("service") else { return nil }
            service = s
        } else {
            service = ""
        }
        let tty = p.string("tty") ?? ""
        let rhost = p.string("rhost") ?? ""
        guard let time = p.long("time"), let nonce = p.string("nonce") else { return nil }
        let timeout = min(max(p.int("timeout") ?? defaultTimeout, minTimeout), maxTimeout)
        let fields = [host, user, service, tty, rhost]
        guard fields.allSatisfy(validField), !host.isEmpty, !user.isEmpty, validNonce(nonce) else { return nil }
        if kind == .approve, service.isEmpty { return nil }
        return ApproveRequest(
            computerId: computerId, computerName: computerName, id: id, kind: kind,
            host: host, user: user, service: service, tty: tty, rhost: rhost,
            time: time, nonce: nonce, timeoutSeconds: timeout
        )
    }

    /// Reads the request id of a `cancel` packet (Go `ApproveCancel` → phone).
    /// Nil for other kinds and empty ids.
    static func cancelId(_ p: Packet) -> String? {
        guard p.type == PacketType.fluxApprove, p.string("kind") == "cancel",
              let id = p.string("id"), !id.isEmpty
        else { return nil }
        return id
    }

    /// Reports whether the signed time is within 10 minutes of the phone
    /// clock (Android `fresh`, `MAX_SKEW_SECONDS`).
    static func fresh(_ r: ApproveRequest, nowSeconds: Int64) -> Bool {
        abs(nowSeconds - r.time) <= freshnessWindow
    }

    /// The question on the phone, e.g. "Approve sudo for user alice on host
    /// omarchy-xps?" (Android `question`).
    static func question(_ r: ApproveRequest) -> String {
        switch r.kind {
        case .approve:
            return "Approve \(r.service) for user \(r.user) on host \(r.host)?"
        case .enroll:
            return "Use this phone to approve sudo for user \(r.user) on host \(r.host)?"
        }
    }

    // MARK: - Replies (phone→desktop, Go `handleApprove` states)

    /// Sends the DER signature of the approval message
    /// (Go `approved` → helper `Verify`).
    static func approved(id: String, signature: Data) -> Packet {
        Packet.of(PacketType.fluxApprove,
                  ("kind", "response"), ("id", id),
                  ("signature", signature.base64EncodedString()))
    }

    /// Sends a denial (Go `denied` → helper `ErrDenied`).
    static func denied(id: String) -> Packet {
        Packet.of(PacketType.fluxApprove,
                  ("kind", "response"), ("id", id), ("denied", true))
    }

    /// Sends an error (Go `failed`; the message is cut to 200 chars like
    /// Android, and `cleanMessage` on the desktop replaces rule-breakers).
    static func failed(id: String, message: String) -> Packet {
        Packet.of(PacketType.fluxApprove,
                  ("kind", "response"), ("id", id),
                  ("error", String(message.prefix(200))))
    }

    /// Sends the new public key (SPKI DER) plus the proof that the phone
    /// holds the private key (Go `enrolled` → helper `VerifyEnrollment`).
    static func enrolled(id: String, spki: Data, signature: Data) -> Packet {
        Packet.of(PacketType.fluxApprove,
                  ("kind", "enrolled"), ("id", id),
                  ("publicKey", spki.base64EncodedString()),
                  ("signature", signature.base64EncodedString()))
    }
}
