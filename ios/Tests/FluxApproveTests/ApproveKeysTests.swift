import XCTest
@testable import FluxApprove
@testable import FluxProto
#if canImport(Security)
import Security
#endif

/// Key lifecycle + fail-closed signature checks. The biometric gate itself
/// needs a finger (device-gated, like the M5 capture runs); everything else
/// — create/has/delete, DER sign/verify round-trips, wrong-key/tampered/
/// replay/stale rejection, the attribute builder — runs on this Mac with
/// test keys (`createTestKey`, never the biometric path).
final class ApproveKeysTests: XCTestCase {
    private var computerId: String!

    override func setUp() {
        super.setUp()
        computerId = "test-\(UUID().uuidString)"
    }

    override func tearDown() {
        if let id = computerId { ApproveKeys.delete(computerId: id) }
        super.tearDown()
    }

    private func approvalBytes(nonce: String = ApproveMessage.testNonce, time: Int64 = 1_790_000_000) throws -> Data {
        try ApproveMessage.approval(
            host: "omarchy-xps", user: "alice", service: "sudo",
            tty: "/dev/pts/3", rhost: "", time: time, nonce: nonce)
    }

    // MARK: - Alias + attributes (no Keychain needed)

    func testAliasMatchesAndroid() {
        XCTAssertEqual("flux-approve-pc1", ApproveKeys.alias(computerId: "pc1"))
    }

#if canImport(Security)
    func testSignErrorMapping() {
        // Device finding 2026-09-27 (iPhone SE2): an invalidated Enclave
        // key dies AFTER a successful Touch ID as CryptoTokenKit -3
        // ("unable to sign digest", AKSError=-536362999) — not
        // errSecAuthFailed. Both shapes mean the key is dead: delete +
        // enroll again.
        XCTAssertEqual(
            .biometryChanged,
            ApproveKeys.mapSignError(NSError(domain: "CryptoTokenKit", code: -3, userInfo: nil)))
        XCTAssertEqual(
            .biometryChanged,
            ApproveKeys.mapSignError(NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(errSecAuthFailed), userInfo: nil)))
        XCTAssertEqual(
            .authCancelled,
            ApproveKeys.mapSignError(NSError(
                domain: NSOSStatusErrorDomain,
                code: Int(errSecUserCanceled), userInfo: nil)))
        // Unknown sign failures stay failures (fail closed, key kept).
        if case .failed(let m) = ApproveKeys.mapSignError(
            NSError(domain: "CryptoTokenKit", code: -999, userInfo: nil)) {
            XCTAssertTrue(m.contains("-999"))
        } else {
            XCTFail("unknown sign errors must stay failures")
        }
    }
#endif

    func testAttributeBuilder() {
        // Production: the biometric gate is in the attributes.
        let prod = ApproveKeys.keyAttributes(alias: ApproveKeys.alias(computerId: "pc1"), biometric: true, stored: true)
#if canImport(Security)
        let priv = prod[kSecPrivateKeyAttrs as String] as? [String: Any]
        XCTAssertNotNil(priv?[kSecAttrAccessControl as String])
        // kSecAttrApplicationTag must be Data (a known platform pitfall).
        XCTAssertTrue(prod[kSecAttrApplicationTag as String] is Data)
#else
        XCTAssertEqual(true, prod["fluxBiometricGate"] as? Bool)
#endif
        // Test keys: no access control anywhere.
        let test = ApproveKeys.keyAttributes(alias: "x", biometric: false, stored: true)
#if canImport(Security)
        XCTAssertNil(test[kSecPrivateKeyAttrs as String])
        XCTAssertNil(test[kSecAttrAccessControl as String])
#else
        XCTAssertEqual(false, test["fluxBiometricGate"] as? Bool)
#endif
    }

    // MARK: - Lifecycle (needs Security; skipped elsewhere)

    func testLifecycleEphemeral() throws {
        guard securityAvailable else { return }
        XCTAssertFalse(ApproveKeys.has(computerId: computerId))
        let spki = try ApproveKeys.createTestKey(computerId: computerId, stored: false)
        XCTAssertFalse(spki.isEmpty)
        XCTAssertTrue(ApproveKeys.has(computerId: computerId))
        ApproveKeys.delete(computerId: computerId)
        XCTAssertFalse(ApproveKeys.has(computerId: computerId))
    }

    func testLifecycleStored() throws {
        guard securityAvailable else { return }
        try requirePermanentKeys()
        let spki = try ApproveKeys.createTestKey(computerId: computerId, stored: true)
        XCTAssertFalse(spki.isEmpty)
        XCTAssertTrue(ApproveKeys.has(computerId: computerId))
        // Re-enroll replaces the key (Android `create` deletes first).
        let spki2 = try ApproveKeys.createTestKey(computerId: computerId, stored: true)
        XCTAssertNotEqual(spki, spki2)
        XCTAssertTrue(ApproveKeys.has(computerId: computerId))
    }

    func testSignVerifyRoundTrip() throws {
        guard securityAvailable else { return }
        let spki = try ApproveKeys.createTestKey(computerId: computerId, stored: false)
        let msg = try approvalBytes()
        let sig = try ApproveKeys.sign(message: msg, computerId: computerId)
        XCTAssertFalse(sig.isEmpty)
        // DER passthrough: the signature verifies against the exported SPKI.
        XCTAssertTrue(ApproveKeys.verify(signature: sig, message: msg, spki: spki))
    }

    // MARK: - Fail closed (Go `TestVerify` parity)

    func testWrongKeyFails() throws {
        guard securityAvailable else { return }
        let spki = try ApproveKeys.createTestKey(computerId: computerId, stored: false)
        let otherId = "other-\(UUID().uuidString)"
        defer { ApproveKeys.delete(computerId: otherId) }
        let otherSPKI = try ApproveKeys.createTestKey(computerId: otherId, stored: false)
        let msg = try approvalBytes()
        let sig = try ApproveKeys.sign(message: msg, computerId: computerId)
        XCTAssertTrue(ApproveKeys.verify(signature: sig, message: msg, spki: spki))
        XCTAssertFalse(ApproveKeys.verify(signature: sig, message: msg, spki: otherSPKI))
    }

    func testTamperedFieldFails() throws {
        guard securityAvailable else { return }
        let spki = try ApproveKeys.createTestKey(computerId: computerId, stored: false)
        let msg = try approvalBytes()
        let sig = try ApproveKeys.sign(message: msg, computerId: computerId)
        // Attacker flips the service (sudo → sshd): the bytes differ.
        let tampered = try ApproveMessage.approval(
            host: "omarchy-xps", user: "alice", service: "sshd",
            tty: "/dev/pts/3", rhost: "", time: 1_790_000_000, nonce: ApproveMessage.testNonce)
        XCTAssertFalse(ApproveKeys.verify(signature: sig, message: tampered, spki: spki))
        // Flipped signature bits fail too.
        var bad = sig
        bad[bad.count - 1] ^= 0xFF
        XCTAssertFalse(ApproveKeys.verify(signature: bad, message: msg, spki: spki))
        XCTAssertFalse(ApproveKeys.verify(signature: Data(), message: msg, spki: spki))
    }

    func testReplayedSignatureFails() throws {
        guard securityAvailable else { return }
        let spki = try ApproveKeys.createTestKey(computerId: computerId, stored: false)
        let msg = try approvalBytes()
        let sig = try ApproveKeys.sign(message: msg, computerId: computerId)
        // A signature for an earlier request is not valid for a new request
        // with a new nonce (Go `TestVerify` replay case).
        let replayNonce = String(repeating: "ab", count: 32)
        let replay = try approvalBytes(nonce: replayNonce)
        XCTAssertFalse(ApproveKeys.verify(signature: sig, message: replay, spki: spki))
    }

    func testEnrollmentProofIsNotAnApproval() throws {
        guard securityAvailable else { return }
        let spki = try ApproveKeys.createTestKey(computerId: computerId, stored: false)
        let nonce = ApproveMessage.testNonce
        let enroll = try ApproveMessage.enrollment(
            host: "omarchy-xps", user: "alice", spki: spki, time: 1_790_000_000, nonce: nonce)
        let sig = try ApproveKeys.sign(message: enroll, computerId: computerId)
        XCTAssertTrue(ApproveKeys.verify(signature: sig, message: enroll, spki: spki))
        // The enrollment proof is not a valid approval (version line differs).
        let approval = try approvalBytes()
        XCTAssertFalse(ApproveKeys.verify(signature: sig, message: approval, spki: spki))
    }

    func testVerifyRefusesOtherCurves() throws {
        guard securityAvailable else { return }
        // A P-384 SPKI must fail (Go `TestParsePublicKeyRefusesOtherCurves`).
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 384,
            kSecAttrIsPermanent as String: false,
        ]
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(attrs as CFDictionary, &error),
              let pub = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(pub, nil) as Data?
        else { throw ApproveKeys.KeyError.failed("p384 setup") }
        // Raw 97-byte point is not a P-256 SPKI; verify must fail closed.
        let msg = try approvalBytes()
        XCTAssertFalse(ApproveKeys.verify(signature: Data([0x30, 0x00]), message: msg, spki: point))
    }

    func testSignWithoutKeyThrowsNoKey() {
        guard securityAvailable else { return }
        XCTAssertThrowsError(try ApproveKeys.sign(message: Data([1]), computerId: computerId)) { error in
            guard let keyError = error as? ApproveKeys.KeyError else {
                return XCTFail("wrong error type: \(error)")
            }
            XCTAssertEqual(.noKey, keyError)
        }
    }

    func testEnrolledIndexTracksStoredKeys() throws {
        guard securityAvailable else { return }
        try requirePermanentKeys()
        _ = try ApproveKeys.createTestKey(computerId: computerId, stored: true)
        XCTAssertTrue(ApproveKeys.enrolledIDs().contains(computerId))
        ApproveKeys.delete(computerId: computerId)
        XCTAssertFalse(ApproveKeys.enrolledIDs().contains(computerId))
    }

    func testEmptyIndexDeletesItem() throws {
        // M7: removing the last enrolled id must delete the index item
        // itself (not store `[]`), so test runs leave zero Keychain residue.
        guard securityAvailable else { return }
        try requirePermanentKeys()
        _ = try ApproveKeys.createTestKey(computerId: computerId, stored: true)
        XCTAssertFalse(ApproveKeys.enrolledIDs().isEmpty)
        ApproveKeys.delete(computerId: computerId)
        XCTAssertTrue(ApproveKeys.enrolledIDs().isEmpty)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: ApproveKeys.indexService,
            kSecAttrAccount as String: ApproveKeys.indexAccount,
        ]
        var item: CFTypeRef?
        XCTAssertEqual(SecItemCopyMatching(query as CFDictionary, &item), errSecItemNotFound)
    }

    private var securityAvailable: Bool {
#if canImport(Security)
        return true
#else
        return false
#endif
    }

    /// D7 probe: permanent Keychain writes need a signed host with a
    /// keychain access group (unsigned simulator bundles get -34018
    /// errSecMissingEntitlement). Stored-key tests skip with a message
    /// instead of failing; macOS SPM runs (CI) and signed device runs
    /// execute them fully. The probe key is deleted immediately.
    private var permanentKeysAvailable: Bool {
        let tag = "org.omarchy.flux.test.probe.\(UUID().uuidString)"
        var error: Unmanaged<CFError>?
        let attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: Data(tag.utf8),
        ]
        guard SecKeyCreateRandomKey(attrs as CFDictionary, &error) != nil else {
            let code = (error?.takeRetainedValue() as Error? as NSError?)?.code
            return code != Int(errSecMissingEntitlement)
        }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
        ]
        SecItemDelete(query as CFDictionary)
        return true
    }

    private func requirePermanentKeys() throws {
        try XCTSkipIf(
            !permanentKeysAvailable,
            "unsigned test host: permanent Keychain needs keychain-access-groups (-34018); runs on signed devices"
        )
    }
}
