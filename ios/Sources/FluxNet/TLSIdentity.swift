import Foundation
#if canImport(Security)
import Security
#endif
import FluxProto

/// TLS identity helpers: certificate DER, CN extraction, and `SecIdentity`
/// for client authentication.
///
/// The peer's subject CN must equal its plaintext-identity device ID (Go
/// `provider.go finish()` + Android `LanBackend`); the DER bytes are pinned
/// (`TrustValidation`). System trust is never consulted — both sides use
/// self-signed certificates, like Go `serverConfig`/`clientConfig` and
/// Android `AcceptAllTrustManager`.
public enum TLSIdentity {
#if canImport(Security)
    /// Returns the subject common name of the certificate, or nil.
    /// Pure DER parsing (`Certificates.commonName`): the `SecCertificate`
    /// OID-values API is macOS-only, so this path works on iOS too.
    public static func commonName(_ cert: SecCertificate) -> String? {
        Certificates.commonName(certificateDER: certificateDER(cert))
    }

    /// Returns the certificate bytes for pinning.
    public static func certificateDER(_ cert: SecCertificate) -> Data {
        SecCertificateCopyData(cert) as Data
    }

    /// Builds the client identity (certificate + private key) offered during
    /// the handshake. Works with Secure Enclave keys: signing happens inside
    /// the Enclave, no export needed (unlike file-based TLS stacks).
    ///
    /// - macOS: `SecIdentityCreateWithCertificate` finds the permanent key.
    /// - iOS: no constructor exists, so the certificate is persisted under
    ///   `label` (delete-then-add keeps restarts idempotent; the Keychain
    ///   forms the identity from the matching permanent key) and looked up
    ///   as a `kSecClassIdentity` item. First ran on-device in D7 — before
    ///   this persist step the query could never succeed, so the app link
    ///   died before its first socket and iOS never showed the Local
    ///   Network prompt.
    public static func makeIdentity(certificate: SecCertificate, label: String) -> SecIdentity? {
#if os(macOS)
        var out: SecIdentity?
        guard SecIdentityCreateWithCertificate(nil, certificate, &out) == errSecSuccess else { return nil }
        return out
#else
        let match: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecAttrLabel as String: label,
        ]
        SecItemDelete(match as CFDictionary)
        let add: [String: Any] = [
            kSecClass as String: kSecClassCertificate,
            kSecValueRef as String: certificate,
            kSecAttrLabel as String: label,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        let status = SecItemAdd(add as CFDictionary, nil)
        guard status == errSecSuccess || status == errSecDuplicateItem else { return nil }
        var out: CFTypeRef?
        let query: [String: Any] = [
            kSecClass as String: kSecClassIdentity,
            kSecAttrLabel as String: label,
            kSecReturnRef as String: true,
        ]
        guard SecItemCopyMatching(query as CFDictionary, &out) == errSecSuccess,
              let identity = out as! SecIdentity?
        else { return nil }
        // Fail fast (D7): formation can reference the public half when a
        // public item shares the tag — every TLS handshake then dies -50.
        // A 1-byte self-test here turns that into a loud startup error
        // instead of per-connection `handshakeFailed`s.
        var priv: SecKey?
        guard SecIdentityCopyPrivateKey(identity, &priv) == errSecSuccess, let priv else { return nil }
        var sigError: Unmanaged<CFError>?
        guard SecKeyCreateSignature(priv, .ecdsaSignatureMessageX962SHA256, Data([0]) as CFData, &sigError) != nil
        else { return nil }
        return identity
#endif
    }
#endif
}
