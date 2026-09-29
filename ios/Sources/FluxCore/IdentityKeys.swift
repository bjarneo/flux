import Foundation
#if canImport(Security)
import Security
#endif
#if canImport(CryptoKit)
import CryptoKit
#endif

/// Identity key management.
///
/// Security notes (see `docs/ios-plan.md` §2.3 and `docs/approve.md`):
///
/// - The **identity key** (TLS device certificate) must be usable without
///   user interaction — TLS runs while the phone is locked and in the
///   background. It is therefore stored with
///   `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly` and **no**
///   `SecAccessControl` biometric gate.
/// - **Approve keys** (M6) are the opposite: per-desktop P-256 keys gated by
///   `biometryCurrentSet` with per-use `LAContext`. Do not reuse these
///   attributes for the identity key or background links will fail.
/// - The private key lives in the Secure Enclave when available, else in
///   the Keychain. The certificate DER is pinned by the desktop; a changed
///   certificate is a re-pair, never a silent update.
public enum IdentityKeys {
    /// Keychain application tag for the identity private key.
    public static let applicationTag = "org.omarchy.flux.identity-key"

    /// Attribute dictionary for `SecKeyCreateRandomKey` (EC P-256, permanent).
    /// `secureEnclave` selects the token; fall back to Keychain storage
    /// where the Enclave is unavailable (older devices, simulator).
    /// `tag` isolates test/ephemeral keys; production uses `applicationTag`.
    /// (Note: `kSecAttrLabel` is not set here — key generation rejects it.
    /// The iOS identity lookup matches the certificate's label, applied when
    /// the certificate is persisted; see `TLSIdentity.makeIdentity`.)
    public static func keyAttributes(secureEnclave: Bool, tag: String = applicationTag) -> [String: Any] {
        var attrs: [String: Any] = [
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecAttrKeySizeInBits as String: 256,
            kSecAttrIsPermanent as String: true,
            kSecAttrApplicationTag as String: Data(tag.utf8),
        ]
#if canImport(Security)
        if secureEnclave {
            attrs[kSecAttrTokenID as String] = kSecAttrTokenIDSecureEnclave
        }
        attrs[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
#endif
        return attrs
    }

    /// Reports whether the Secure Enclave can hold the identity key.
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

    public enum KeyError: Error, Equatable {
        case unavailable
        case generationFailed(Int)
    }

    /// Generates (or returns) the identity P-256 private key. Prefers the
    /// Secure Enclave; falls back to Keychain storage.
    public static func loadOrCreate(tag: String = applicationTag) throws -> AnyObject {
#if canImport(Security)
        // D7 device finding: keygen stores a PUBLIC item beside the private
        // key under the same tag, and iOS TLS identity formation can grab
        // the public half — every handshake then fails -50 signing with an
        // ECPublicKey. Nothing reads the public item (SPKI re-derives via
        // SecKeyCopyPublicKey), so delete it on both paths. Idempotent.
        deletePublicItem(tag: tag)
        if let existing = load(tag: tag) { return existing }
        var error: Unmanaged<CFError>?
        guard let key = SecKeyCreateRandomKey(
            keyAttributes(secureEnclave: secureEnclaveAvailable, tag: tag) as CFDictionary, &error
        ) else {
            throw KeyError.generationFailed((error?.takeRetainedValue() as Error? as NSError?)?.code ?? -1)
        }
        deletePublicItem(tag: tag)
        return key
#else
        throw KeyError.unavailable
#endif
    }

    /// Removes the public-key item keygen stores next to the private key
    /// (same application tag). See `loadOrCreate`.
    public static func deletePublicItem(tag: String = applicationTag) {
#if canImport(Security)
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyClass as String: kSecAttrKeyClassPublic,
        ]
        SecItemDelete(query as CFDictionary)
#endif
    }

#if canImport(Security)
    /// Returns the stored identity key, if any.
    public static func load(tag: String = applicationTag) -> SecKey? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
            kSecAttrKeyType as String: kSecAttrKeyTypeECSECPrimeRandom,
            kSecReturnRef as String: true,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return (item as! SecKey)
    }

    /// Deletes the identity key (unpair-everything / fresh-install path).
    /// Key generation stores two items (public + private), and each
    /// `SecItemDelete` removes one match, so this loops to a clean slate.
    public static func delete(tag: String = applicationTag) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassKey,
            kSecAttrApplicationTag as String: Data(tag.utf8),
        ]
        for _ in 0..<8 {
            if SecItemDelete(query as CFDictionary) != errSecSuccess { break }
        }
    }
#endif
}
