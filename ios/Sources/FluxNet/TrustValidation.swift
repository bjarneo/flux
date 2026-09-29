import Foundation

/// Post-handshake peer validation.
///
/// Mirrors Go `provider.go finish()` + Android `net/LanBackend.kt` link
/// checks + `net/Payload.kt` peer check:
///
/// 1. The peer must present a certificate.
/// 2. Its subject CN must equal the plaintext-identity device ID (binds the
///    unauthenticated pre-TLS identity to the TLS endpoint).
/// 3. When a certificate is pinned (paired), the presented bytes must match
///    exactly. A replacement certificate is a re-pair, never a silent
///    update — both sides surface it and the user confirms the key again.
///
/// The TLS handshake itself accepts any self-signed certificate (like Go
/// `serverConfig`/`clientConfig` and Android `AcceptAllTrustManager` with
/// TLS 1.2); authentication happens here, after the handshake.
public enum TrustValidation {
    public enum Failure: Sendable, Equatable, Error {
        /// The peer sent no certificate.
        case noCertificate
        /// CN does not match the plaintext device ID.
        case identityMismatch(commonName: String, deviceId: String)
        /// Pinned bytes differ: the peer reinstalled or is impersonated.
        /// Forget trust and re-pair; never silently accept.
        case certificateChanged(deviceName: String)
    }

    /// Validates the peer. `peerDER` is the presented leaf in DER;
    /// `pinnedDER` is the stored pin, or nil when never paired.
    public static func validate(
        commonName: String?,
        peerDER: Data?,
        expectedDeviceId: String,
        deviceName: String,
        pinnedDER: Data?
    ) -> Result<Void, Failure> {
        guard let peerDER, let commonName else { return .failure(.noCertificate) }
        guard commonName == expectedDeviceId else {
            return .failure(.identityMismatch(commonName: commonName, deviceId: expectedDeviceId))
        }
        if let pinnedDER, pinnedDER != peerDER {
            return .failure(.certificateChanged(deviceName: deviceName))
        }
        return .success(())
    }
}
