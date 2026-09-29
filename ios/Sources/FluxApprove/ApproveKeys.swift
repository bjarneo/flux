import Foundation
import FluxProto
#if canImport(Security)
import Security
#endif
#if canImport(LocalAuthentication)
import LocalAuthentication
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// The approval keys, one per paired computer. Port of Android
/// `core/ApproveKeys.kt`; `docs/approve.md` "Keys on the phone" is the
/// contract: EC P-256, SHA-256 only, per-use biometric auth, key invalid
/// after a new biometric enrollment (re-enroll), Secure Enclave when
/// available.
///
/// Alias scheme (matches Android exactly): `flux-approve-<computer device ID>`.
///
/// Threat-model notes (see `docs/approve.md` §5):
/// - Production keys are created with `biometryCurrentSet` access control:
///   every signature needs a fresh Face ID / Touch ID through a per-use
///   `LAContext`, and a new biometric enrollment invalidates the key.
///   There is deliberately NO non-biometric creation path for production.
/// - `createTestKey` is test-harness-only (`--exercise-m6` "TEST MODE (no
///   biometric)" + unit tests). It uses the same alias scheme and the same
///   P-256/DER wire, but plain Keychain/memory storage. Grep for
///   `createTestKey` to audit every bypass of the biometric gate.
public enum ApproveKeys {
    /// Keychain application tag for the approval key of a computer
    /// (Android `ApproveKeys.alias`).
    public static func alias(computerId: String) -> String {
        "flux-approve-\(computerId)"
    }

    public enum KeyError: Error, Equatable {
        /// No approval key for this computer (enroll first).
        case noKey
        /// The biometrics changed: the key is invalid, delete it and enroll
        /// again (Android `KeyPermanentlyInvalidatedException` path). The
        /// caller deletes the alias and answers `biometryChangedProblem`.
        case biometryChanged
        /// Biometric auth was cancelled without invalidating the key.
        case authCancelled
        /// Key creation or signing failed for another reason.
        case failed(String)
        /// The Security framework is unavailable (non-Apple platform).
        case unavailable
    }

    /// Reports whether the Secure Enclave can hold approval keys.
    public static var secureEnclaveAvailable: Bool {
#if canImport(CryptoKit)
        if #available(iOS 11.0, macOS 10.13, *) {
            return SecureEnclave.isAvailable
        }
        return false
#else
        return false
#endif
    }

    /// Reports whether the device can do per-use biometric auth
    /// (Android `BiometricManager.canAuthenticate(BIOMETRIC_STRONG)` gate).
    public static var biometryAvailable: Bool {
#if canImport(LocalAuthentication)
        LAContext().canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil)
#else
        return false
#endif
    }

    // MARK: - Production keys (biometric-gated)

    /// Makes a new biometric-gated approval key for a computer and returns
    /// its public key (SPKI DER) for the `enrolled` reply. An old key for
    /// the computer goes away first (Android `create`).
    ///
    /// The caller must have checked `biometryAvailable` and must sign only
    /// through a biometrically-authed `LAContext` (see `sign`).
    @discardableResult
    public static func create(computerId: String) throws -> Data {
#if canImport(Security)
        delete(computerId: computerId)
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(
            keyAttributes(alias: alias(computerId: computerId), biometric: true, stored: true) as CFDictionary,
            &error
        ) else {
            throw KeyError.failed("create: \((error?.takeRetainedValue() as Error? as NSError?)?.code ?? -1)")
        }
        guard let spki = exportSPKI(key) else { throw KeyError.failed("create: no public key") }
        noteEnrolled(computerId)
        return spki
#else
        throw KeyError.unavailable
#endif
    }

    /// Signs `message` with the approval key of a computer and returns the
    /// ASN.1 DER signature for the wire. The bytes pass through unchanged
    /// (SecureTransport returns DER; Go `ecdsa.VerifyASN1` expects DER).
    ///
    /// - `context`: a per-use `LAContext` that already passed biometric
    ///   auth (pass as `Any?` so the API compiles without
    ///   LocalAuthentication). Nil only for keys without access control
    ///   (unit tests).
    public static func sign(message: Data, computerId: String, context: Any? = nil) throws -> Data {
#if canImport(Security)
        guard let key = lookup(alias: alias(computerId: computerId), context: context) else {
            throw KeyError.noKey
        }
        var error: Unmanaged<CFError>?
        guard let sig = SecKeyCreateSignature(
            key, .ecdsaSignatureMessageX962SHA256, message as CFData, &error
        ) as Data? else {
            throw mapSignError(error?.takeRetainedValue() as Error? as NSError?)
        }
        return sig
#else
        throw KeyError.unavailable
#endif
    }

    // MARK: - Test keys (no biometric gate; harness + unit tests only)

    /// Makes a P-256 key under the production alias scheme WITHOUT the
    /// biometric gate. TEST HARNESS ONLY — every caller must log
    /// "TEST MODE (no biometric)". `stored` selects a Keychain item
    /// (tracked for `--forget`) vs. an in-memory key (zero residue).
    @discardableResult
    public static func createTestKey(computerId: String, stored: Bool) throws -> Data {
#if canImport(Security)
        delete(computerId: computerId)
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(
            keyAttributes(alias: alias(computerId: computerId), biometric: false, stored: stored) as CFDictionary,
            &error
        ) else {
            throw KeyError.failed("createTestKey: \((error?.takeRetainedValue() as Error? as NSError?)?.code ?? -1)")
        }
        guard let spki = exportSPKI(key) else { throw KeyError.failed("createTestKey: no public key") }
        if stored { noteEnrolled(computerId) }
        TestKeysRemember.remember(computerId: computerId, key: key, stored: stored)
        return spki
#else
        throw KeyError.unavailable
#endif
    }

    // MARK: - Lookup + delete

    /// Reports whether an approval key exists for a computer.
    public static func has(computerId: String) -> Bool {
#if canImport(Security)
        // In-memory test keys count too (harness ephemeral mode).
        if TestKeysRemember.has(computerId: computerId) { return true }
        return lookup(alias: alias(computerId: computerId), context: nil) != nil
#else
        return false
#endif
    }

    /// Deletes the approval key of a computer (unpair / re-enroll /
    /// invalidated-key cleanup). Key generation stores two items
    /// (public + private), so this loops to a clean slate like
    /// `IdentityKeys.delete`.
    ///
    /// Memory-only test keys (`createTestKey(stored:false)`) never touch
    /// the Keychain, so deleting them skips it too — no SecItem traffic
    /// for keys that cannot have Keychain residue. Anything else (real
    /// stored keys, including ones this process did not create) takes the
    /// full Keychain delete + index cleanup.
    public static func delete(computerId: String) {
#if canImport(Security)
        let memoryOnly = TestKeysRemember.forget(computerId: computerId)
        guard !memoryOnly else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(alias(computerId: computerId).utf8),
        ]
        for _ in 0..<8 {
            if SecItemDelete(query as CFDictionary) != errSecSuccess { break }
        }
        forgetEnrolled(computerId)
#endif
    }

    /// Deletes every enrolled approval key (`FluxTestPeer --forget`,
    /// fresh-install path). Returns the number removed.
    @discardableResult
    public static func deleteAllEnrolled() -> Int {
#if canImport(Security)
        var count = 0
        for id in enrolledIDs() {
            delete(computerId: id)
            count += 1
        }
        return count
#else
        return 0
#endif
    }

    // MARK: - Verification (enrollment self-check)

    /// Checks a DER signature over `message` with the P-256 key in `spki`
    /// (DER). Fail-closed: any parse or crypto failure is `false`, never an
    /// error (Go `verify` → `ErrBadSignature` parity).
    ///
    /// CryptoKit verifies what Security signs — the same cross-library shape
    /// as production (the phone signs with the Enclave/Security, the desktop
    /// helper verifies with Go). Non-P-256 keys fail closed.
    ///
    /// Used as the enrollment self-check before sending the pubkey, and by
    /// the fail-closed unit tests. The desktop helper does the same check
    /// with the enrolled key file.
    public static func verify(signature: Data, message: Data, spki: Data) -> Bool {
#if canImport(CryptoKit)
        if #available(iOS 13.0, macOS 10.15, *) {
            do {
                let key = try P256.Signing.PublicKey(derRepresentation: spki)
                let sig = try P256.Signing.ECDSASignature(derRepresentation: signature)
                return key.isValidSignature(sig, for: SHA256.hash(data: message))
            } catch {
                return false
            }
        }
        return false
#else
        return false
#endif
    }

    // MARK: - Attribute builder (unit-tested without touching the Keychain)

    /// Attribute dictionary for `SecKeyCreateRandomKey` (EC P-256).
    /// `biometric` selects the production gate
    /// (`biometryCurrentSet` + `privateKeyUsage`, Secure Enclave token when
    /// available — Android `setUserAuthenticationParameters(0,
    /// AUTH_BIOMETRIC_STRONG)` + StrongBox-when-available parity).
    /// `stored` selects a permanent Keychain item vs. an in-memory key.
    /// Note: `kSecAttrApplicationTag` must be `Data` (not String).
    public static func keyAttributes(alias: String, biometric: Bool, stored: Bool) -> [String: Any] {
#if canImport(Security)
        var attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: stored,
            kSecAttrApplicationTag as String: Data(alias.utf8),
        ]
        if biometric {
            if secureEnclaveAvailable {
                attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
            }
            var accessError: Unmanaged<CFError>?
            if let access = SecAccessControlCreateWithFlags(
                nil,
                kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
                [.biometryCurrentSet, .privateKeyUsage],
                &accessError
            ) {
                attrs[kSecPrivateKeyAttrs as String] = [
                    kSecAttrIsPermanent as String: stored,
                    kSecAttrApplicationTag as String: Data(alias.utf8),
                    kSecAttrAccessControl as String: access,
                ]
            }
        } else if stored {
            attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        }
        return attrs
#else
        // No Security framework (non-Apple CI): describe the intent so the
        // gate choice stays unit-testable everywhere.
        return [
            "fluxAlias": alias,
            "fluxBiometricGate": biometric,
            "fluxStored": stored,
        ]
#endif
    }

#if canImport(Security)
    // MARK: - Internal (Security)

    static func lookup(alias: String, context: Any?) -> SecKey? {
        if let key = TestKeysRemember.key(computerId: computerId(of: alias)) { return key }
        var query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(alias.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            // Signing needs the private half: keygen stores a public item
            // under the same tag, and either could match without this.
            kSecAttrKeyClass as String: kSecAttrKeyClassPrivate,
            kSecReturnRef as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
#if canImport(LocalAuthentication)
        if let context = context as? LAContext {
            query[kSecUseAuthenticationContext as String] = context
        }
#endif
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecKey)
    }

    /// Maps the alias back to the computer id for the in-memory test store.
    static func computerId(of alias: String) -> String {
        alias.hasPrefix("flux-approve-") ? String(alias.dropFirst("flux-approve-".count)) : alias
    }

    static func exportSPKI(_ key: SecKey) -> Data? {
        guard let pub = SecKeyCopyPublicKey(key),
              let point = SecKeyCopyExternalRepresentation(pub, nil) as Data?
        else { return nil }
        return Certificates.spkiFromUncompressedPoint(point)
    }

    /// Fail-closed error mapping. An invalidated `biometryCurrentSet` key
    /// (new biometric enrollment) surfaces as `errSecAuthFailed` on use —
    /// or, on current iOS, as CryptoTokenKit `-3` ("unable to sign digest",
    /// AKSError=-536362999) AFTER a successful Touch ID: the finger passes
    /// and then the Enclave refuses (proven on hardware 2026-09-27, iPhone
    /// SE2). Both mean the key is dead — the caller deletes the alias and
    /// answers the enroll-again error (Android
    /// `KeyPermanentlyInvalidatedException` path).
    static func mapSignError(_ error: NSError?) -> KeyError {
        guard let error else { return .failed("sign: unknown") }
        if error.code == Int(errSecAuthFailed) { return .biometryChanged }
        if error.code == Int(errSecUserCanceled) { return .authCancelled }
        if error.domain == "CryptoTokenKit", error.code == -3 { return .biometryChanged }
        return .failed("sign: \(error.domain) \(error.code)")
    }

    // MARK: - Enrolled-computer index (for `--forget`)

    static let indexService = "org.omarchy.flux.approve"
    static let indexAccount = "computers"

    static func enrolledIDs() -> [String] {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: indexService,
            kSecAttrAccount as String: indexAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let ids = try? JSONDecoder().decode([String].self, from: data)
        else { return [] }
        return ids
    }

    static func noteEnrolled(_ computerId: String) {
        var ids = Set(enrolledIDs())
        guard ids.insert(computerId).inserted else { return }
        saveIndex(Array(ids))
    }

    static func forgetEnrolled(_ computerId: String) {
        var ids = Set(enrolledIDs())
        guard ids.remove(computerId) != nil else { return }
        saveIndex(Array(ids))
    }

    private static func saveIndex(_ ids: [String]) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: indexService,
            kSecAttrAccount as String: indexAccount,
        ]
        guard !ids.isEmpty else {
            // M7: an empty index deletes the item instead of storing `[]`,
            // so unit-test runs and `--forget` leave zero Keychain residue.
            SecItemDelete(query as CFDictionary)
            return
        }
        guard let data = try? JSONEncoder().encode(ids) else { return }
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = false
            SecItemAdd(add as CFDictionary, nil)
        }
    }
#endif
}

#if canImport(Security)
/// In-memory holder for ephemeral test keys (harness non-persist mode):
/// `SecKeyCreateRandomKey` with `isPermanent=false` returns keys the
/// Keychain never sees, so ephemeral runs leave zero residue and need no
/// cleanup. Keyed by computer id. Remembers which keys are memory-only so
/// `delete` can skip Keychain traffic for them.
private final class TestKeysRemember: @unchecked Sendable {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var keys: [String: SecKey] = [:]
    nonisolated(unsafe) private static var memoryOnly: Set<String> = []

    static func remember(computerId: String, key: SecKey, stored: Bool) {
        lock.withLock {
            keys[computerId] = key
            if stored { memoryOnly.remove(computerId) } else { memoryOnly.insert(computerId) }
        }
    }

    static func key(computerId: String) -> SecKey? {
        lock.withLock { keys[computerId] }
    }

    static func has(computerId: String) -> Bool {
        lock.withLock { keys[computerId] != nil }
    }

    /// Forgets the key. Returns true when it was memory-only (no Keychain
    /// residue possible, caller skips SecItem work). Unknown ids return
    /// false so stored keys from earlier processes take the full delete.
    @discardableResult
    static func forget(computerId: String) -> Bool {
        lock.withLock {
            let mem = memoryOnly.remove(computerId) != nil
            keys.removeValue(forKey: computerId)
            return mem
        }
    }
}
#endif
