import CryptoKit
import Foundation

/// A request from a computer: approve a login with Touch ID, or make the key
/// for approvals. docs/approve.md is the security design.
public struct ApproveRequest: Sendable, Equatable, Identifiable {
    public enum Kind: String, Sendable {
        case approve, enroll
    }

    public var computerId: String
    public var computerName: String
    public var id: String
    public var kind: Kind
    public var host: String
    public var user: String
    public var service: String
    public var tty: String
    public var rhost: String
    /// The Unix time in seconds when the computer made the request.
    public var time: Int64
    /// 32 random bytes as 64 lowercase hex digits.
    public var nonce: String
    public var timeoutSeconds: Int
}

/// The signed messages and the packets of approvals. The tests check that it
/// builds the same bytes as the Go helper and Flux for Android.
public enum ApproveMessage {
    static let maxField = 256

    /// How far the time of a request can be from the clock of this Mac.
    public static let maxSkewSeconds: Int64 = 600

    /// At most 256 bytes of UTF-8, and no control character. A Swift string
    /// is always valid Unicode, so the UTF-8 is valid too.
    public static func validField(_ v: String) -> Bool {
        guard v.utf8.count <= maxField else { return false }
        return v.unicodeScalars.allSatisfy { s in
            !(s.value < 0x20 || s.value == 0x7F || (0x80...0x9F).contains(s.value))
        }
    }

    /// Exactly 64 lowercase hex digits.
    public static func validNonce(_ n: String) -> Bool {
        n.utf8.count == 64 && n.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// The exact bytes that this Mac signs to approve the request.
    public static func approval(_ r: ApproveRequest) -> Data {
        var s = "flux-approve-v1\n"
        s += "host=\(r.host)\n"
        s += "user=\(r.user)\n"
        s += "service=\(r.service)\n"
        s += "tty=\(r.tty)\n"
        s += "rhost=\(r.rhost)\n"
        s += "time=\(r.time)\n"
        s += "nonce=\(r.nonce)\n"
        return Data(s.utf8)
    }

    /// The exact bytes that the new key signs to prove that this Mac holds it.
    /// `spki` is the public key in DER.
    public static func enrollment(_ r: ApproveRequest, spki: Data) -> Data {
        var s = "flux-approve-enroll-v1\n"
        s += "host=\(r.host)\n"
        s += "user=\(r.user)\n"
        s += "key=\(hex(Data(SHA256.hash(data: spki))))\n"
        s += "time=\(r.time)\n"
        s += "nonce=\(r.nonce)\n"
        return Data(s.utf8)
    }

    /// The key code that this Mac and the terminal show: the first 8 bytes of
    /// the SHA-256 of the key in DER, as 4 groups of 4 hex digits.
    public static func fingerprint(_ spki: Data) -> String {
        let h = hex(Data(SHA256.hash(data: spki)).prefix(8)).uppercased()
        return stride(from: 0, to: h.count, by: 4).map { i in
            let start = h.index(h.startIndex, offsetBy: i)
            return String(h[start..<h.index(start, offsetBy: 4)])
        }.joined(separator: " ")
    }

    /// Reads a request or an enrollment. It returns nil for a packet that
    /// breaks a rule.
    public static func parse(_ p: Packet, computerId: String, computerName: String) -> ApproveRequest? {
        let kind: ApproveRequest.Kind
        switch p.string("kind") {
        case "request": kind = .approve
        case "enroll": kind = .enroll
        default: return nil
        }
        guard let id = p.string("id"), !id.isEmpty, id.utf16.count <= 64, validField(id),
              let host = p.string("host"), let user = p.string("user"),
              let time = p.long("time"), validTime(time), let nonce = p.string("nonce") else { return nil }
        let service: String
        if kind == .approve {
            guard let s = p.string("service") else { return nil }
            service = s
        } else {
            service = ""
        }
        let r = ApproveRequest(
            computerId: computerId,
            computerName: computerName,
            id: id,
            kind: kind,
            host: host,
            user: user,
            service: service,
            tty: p.string("tty") ?? "",
            rhost: p.string("rhost") ?? "",
            time: time,
            nonce: nonce,
            timeoutSeconds: min(max(p.int("timeout") ?? 20, 5), 120)
        )
        guard [r.host, r.user, r.service, r.tty, r.rhost].allSatisfy(validField),
              !r.host.isEmpty, !r.user.isEmpty, validNonce(r.nonce) else { return nil }
        if kind == .approve && r.service.isEmpty { return nil }
        return r
    }

    /// Reports whether the time of the request is within 10 minutes of the
    /// clock of this Mac. The subtraction reports an overflow instead of a
    /// trap, and a time that overflows is not fresh.
    public static func fresh(_ r: ApproveRequest, now: Int64) -> Bool {
        let (d, overflow) = now.subtractingReportingOverflow(r.time)
        return !overflow && d.magnitude <= UInt64(maxSkewSeconds)
    }

    /// Reports whether a request time in seconds is possible: above 0 and
    /// at most 2^40, about the year 36812. The helper sends the time of now.
    static func validTime(_ t: Int64) -> Bool { t > 0 && t <= 1 << 40 }

    /// The question, for example "Approve sudo for user alice on host omarchy-xps?".
    public static func question(_ r: ApproveRequest) -> String {
        switch r.kind {
        case .approve: return "Approve \(r.service) for user \(r.user) on host \(r.host)?"
        case .enroll: return ApproveTexts.current.enrollQuestion(user: r.user, host: r.host)
        }
    }

    public static func approved(_ id: String, signature: Data) -> Packet {
        Packet(PacketType.fluxApprove, ["kind": "response", "id": id, "signature": signature.base64EncodedString()])
    }

    public static func denied(_ id: String) -> Packet {
        Packet(PacketType.fluxApprove, ["kind": "response", "id": id, "denied": true])
    }

    public static func failed(_ id: String, message: String) -> Packet {
        Packet(PacketType.fluxApprove, ["kind": "response", "id": id, "error": String(message.prefix(200))])
    }

    public static func enrolled(_ id: String, spki: Data, signature: Data) -> Packet {
        Packet(PacketType.fluxApprove, [
            "kind": "enrolled", "id": id, "publicKey": spki.base64EncodedString(), "signature": signature.base64EncodedString(),
        ])
    }

    static func hex<D: Sequence>(_ bytes: D) -> String where D.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
