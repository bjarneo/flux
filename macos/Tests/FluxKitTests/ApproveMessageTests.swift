import CryptoKit
import XCTest
@testable import FluxKit

/// The vectors are the same as in the Go test internal/approve/message_test.go
/// and the Android test ApproveMessageTest, so that this Mac signs the bytes
/// that the helper checks.
final class ApproveMessageTests: XCTestCase {
    private let nonce = "00112233445566778899aabbccddeeff00112233445566778899aabbccddeeff"

    private lazy var request = ApproveRequest(
        computerId: "pc1", computerName: "omarchy-xps", id: "req1", kind: .approve,
        host: "omarchy-xps", user: "alice", service: "sudo", tty: "/dev/pts/3", rhost: "",
        time: 1_790_000_000, nonce: nonce, timeoutSeconds: 20
    )

    /// A P-256 key, its SubjectPublicKeyInfo, and signatures that Go made
    /// with x509.MarshalPKIXPublicKey and ecdsa.SignASN1.
    private let goScalar = "c9afa9d845ba75166b5c215767b1d6934e50c3db36e89b127b8a622b120f6721"
    private let goSPKI = "MFkwEwYHKoZIzj0CAQYIKoZIzj0DAQcDQgAEYP7UuiVanTHJYet0xjVtaMBJuJI7Yfps5mliLmDyn7Z5A/4QCLi8maQa6elWKLxk8vGyDC1+n1F3o8KU1EYimQ=="
    private let goApproval = "MEQCIC9nhVHDkdMjLMD2zhHiL3z6g5BTHJJja1ab9OBsZ/ItAiAbjR9eAaoWgvL+8lQhHo4oYVYGxUyOqiI6xcw9gZDgVA=="
    private let goEnrollment = "MEYCIQCRP4zk0TYxBaRM30naSWJ52MvOcMIvNw6rFQKxhT+96gIhAO7ZR5DQk4uvPQo6eX0twkl8aT2RMJteb0yORkgFfxJ5"

    func testApprovalBytes() {
        let want = "flux-approve-v1\nhost=omarchy-xps\nuser=alice\nservice=sudo\ntty=/dev/pts/3\nrhost=\ntime=1790000000\nnonce=\(nonce)\n"
        XCTAssertEqual(String(decoding: ApproveMessage.approval(request), as: UTF8.self), want)
    }

    func testEnrollmentBytes() {
        var e = request
        e.kind = .enroll
        e.service = ""
        e.tty = ""
        let want = "flux-approve-enroll-v1\nhost=omarchy-xps\nuser=alice\n"
            + "key=62af8704764faf8ea82fc61ce9c4c3908b6cb97d463a634e9e587d7c885db0ef\n"
            + "time=1790000000\nnonce=\(nonce)\n"
        XCTAssertEqual(String(decoding: ApproveMessage.enrollment(e, spki: Data("test-key".utf8)), as: UTF8.self), want)
    }

    func testFingerprint() {
        XCTAssertEqual(ApproveMessage.fingerprint(Data("test-key".utf8)), "62AF 8704 764F AF8E")
        XCTAssertEqual(ApproveMessage.fingerprint(Data(base64Encoded: goSPKI)!), "5A7A 78CC A4A0 F420")
    }

    func testPublicKeyDERMatchesGo() throws {
        let key = try P256.Signing.PrivateKey(rawRepresentation: hexBytes(goScalar))
        XCTAssertEqual(key.publicKey.derRepresentation.base64EncodedString(), goSPKI)
    }

    func testGoSignaturesVerifyOverTheSameBytes() throws {
        let pub = try P256.Signing.PublicKey(derRepresentation: Data(base64Encoded: goSPKI)!)
        let approval = try P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded: goApproval)!)
        XCTAssertTrue(pub.isValidSignature(approval, for: ApproveMessage.approval(request)))

        var e = request
        e.kind = .enroll
        let enrollment = try P256.Signing.ECDSASignature(derRepresentation: Data(base64Encoded: goEnrollment)!)
        XCTAssertTrue(pub.isValidSignature(enrollment, for: ApproveMessage.enrollment(e, spki: Data(base64Encoded: goSPKI)!)))

        // A signature for an enrollment is never a valid approval.
        XCTAssertFalse(pub.isValidSignature(enrollment, for: ApproveMessage.approval(request)))
        var changed = request
        changed.service = "polkit-1"
        XCTAssertFalse(pub.isValidSignature(approval, for: ApproveMessage.approval(changed)))
    }

    func testFieldRules() {
        XCTAssertTrue(ApproveMessage.validField("/dev/pts/3"))
        XCTAssertTrue(ApproveMessage.validField(""))
        XCTAssertTrue(ApproveMessage.validField("Pixel 8 · Office"))
        XCTAssertFalse(ApproveMessage.validField("alice\nservice=sshd"))
        XCTAssertFalse(ApproveMessage.validField("tab\there"))
        XCTAssertFalse(ApproveMessage.validField("c1\u{85}"))
        XCTAssertFalse(ApproveMessage.validField("del\u{7f}"))
        XCTAssertFalse(ApproveMessage.validField(String(repeating: "x", count: 257)))
        XCTAssertTrue(ApproveMessage.validField(String(repeating: "x", count: 256)))
        // 129 characters of 2 bytes each are 258 bytes.
        XCTAssertFalse(ApproveMessage.validField(String(repeating: "é", count: 129)))
        XCTAssertTrue(ApproveMessage.validNonce(nonce))
        XCTAssertFalse(ApproveMessage.validNonce(nonce.uppercased()))
        XCTAssertFalse(ApproveMessage.validNonce(String(nonce.dropLast(2))))
    }

    private func packet(_ extra: [String: Any?] = [:]) -> Packet {
        var fields: [String: Any?] = [
            "kind": "request", "id": "req1", "host": "omarchy-xps", "user": "alice", "service": "sudo",
            "tty": "/dev/pts/3", "rhost": "", "time": Int64(1_790_000_000), "nonce": nonce, "timeout": 20,
        ]
        for (k, v) in extra { fields[k] = v }
        return Packet(PacketType.fluxApprove, fields.compactMapValues { $0 })
    }

    func testParseRequest() throws {
        let r = try XCTUnwrap(ApproveMessage.parse(packet(), computerId: "pc1", computerName: "omarchy-xps"))
        XCTAssertEqual(r, request)
        XCTAssertEqual(ApproveMessage.question(r), "Approve sudo for user alice on host omarchy-xps?")
    }

    func testParseSurvivesTheWireFormat() throws {
        let line = packet().serialize()
        let back = try XCTUnwrap(Packet.parse(line))
        XCTAssertEqual(ApproveMessage.parse(back, computerId: "pc1", computerName: "omarchy-xps"), request)
    }

    func testParseRefusesBadRequests() {
        XCTAssertNil(ApproveMessage.parse(packet(["user": "alice\nservice=sshd"]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["nonce": "abcd"]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["host": ""]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["service": ""]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["kind": "other"]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["id": ""]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["id": String(repeating: "a", count: 65)]), computerId: "pc1", computerName: "pc"))
        XCTAssertNil(ApproveMessage.parse(packet(["tty": "tty\u{0}"]), computerId: "pc1", computerName: "pc"))
    }

    func testParseTimeoutLimits() {
        XCTAssertEqual(ApproveMessage.parse(packet(["timeout": 1]), computerId: "pc1", computerName: "pc")?.timeoutSeconds, 5)
        XCTAssertEqual(ApproveMessage.parse(packet(["timeout": 600]), computerId: "pc1", computerName: "pc")?.timeoutSeconds, 120)
        var noTimeout = packet()
        noTimeout.body["timeout"] = nil
        XCTAssertEqual(ApproveMessage.parse(noTimeout, computerId: "pc1", computerName: "pc")?.timeoutSeconds, 20)
    }

    func testParseEnrollment() throws {
        var p = packet(["kind": "enroll"])
        p.body["service"] = nil
        let r = try XCTUnwrap(ApproveMessage.parse(p, computerId: "pc1", computerName: "omarchy-xps"))
        XCTAssertEqual(r.kind, .enroll)
        XCTAssertEqual(r.service, "")
        #if os(macOS)
        XCTAssertEqual(ApproveMessage.question(r), "Use this Mac to approve sudo for user alice on host omarchy-xps?")
        #else
        XCTAssertEqual(ApproveMessage.question(r), "Use this iPhone to approve sudo for user alice on host omarchy-xps?")
        #endif
    }

    func testFreshness() {
        XCTAssertTrue(ApproveMessage.fresh(request, now: request.time + 30))
        XCTAssertTrue(ApproveMessage.fresh(request, now: request.time - 30))
        XCTAssertTrue(ApproveMessage.fresh(request, now: request.time + 600))
        XCTAssertFalse(ApproveMessage.fresh(request, now: request.time + 601))
        XCTAssertFalse(ApproveMessage.fresh(request, now: request.time - 601))
    }

    /// A time near Int64.min made the subtraction trap. Such a time is not fresh.
    func testFreshnessCannotOverflow() {
        for time in [Int64.min, Int64.min + 1, Int64.max, 0, -1] {
            var r = request
            r.time = time
            XCTAssertFalse(ApproveMessage.fresh(r, now: 1_790_000_000), "\(time)")
        }
        XCTAssertFalse(ApproveMessage.fresh(request, now: Int64.min))
        XCTAssertFalse(ApproveMessage.fresh(request, now: Int64.max))
    }

    func testParseRefusesImpossibleTimes() {
        let times: [Any] = [Int64.min, Int64(0), Int64(-1), Int64(1) << 41, "1e19", 1e300]
        for time in times {
            XCTAssertNil(ApproveMessage.parse(packet(["time": time]), computerId: "pc1", computerName: "pc"), "\(time)")
        }
    }

    func testAnswerPackets() throws {
        let sig = Data([1, 2, 3])
        let a = ApproveMessage.approved("req1", signature: sig)
        XCTAssertEqual(a.type, PacketType.fluxApprove)
        XCTAssertEqual(a.string("kind"), "response")
        XCTAssertEqual(a.string("id"), "req1")
        XCTAssertEqual(a.string("signature"), sig.base64EncodedString())
        XCTAssertNil(a.bool("denied"))

        let d = ApproveMessage.denied("req1")
        XCTAssertEqual(d.string("kind"), "response")
        XCTAssertEqual(d.bool("denied"), true)
        XCTAssertNil(d.string("signature"))

        let e = ApproveMessage.enrolled("req1", spki: Data("key".utf8), signature: sig)
        XCTAssertEqual(e.string("kind"), "enrolled")
        XCTAssertEqual(e.string("publicKey"), Data("key".utf8).base64EncodedString())
        XCTAssertEqual(e.string("signature"), sig.base64EncodedString())

        let f = ApproveMessage.failed("req1", message: String(repeating: "x", count: 500))
        XCTAssertEqual(f.string("error")?.count, 200)

        // The denial is a JSON boolean, as the Go handler decodes it.
        let line = String(decoding: d.serialize(), as: UTF8.self)
        XCTAssertTrue(line.contains(#""denied":true"#), line)
        let back = try XCTUnwrap(Packet.parse(a.serialize()))
        XCTAssertEqual(back.string("signature"), a.string("signature"))
    }

    private func hexBytes(_ s: String) -> Data {
        var out = Data()
        var i = s.startIndex
        while i < s.endIndex {
            let j = s.index(i, offsetBy: 2)
            out.append(UInt8(s[i..<j], radix: 16)!)
            i = j
        }
        return out
    }
}
