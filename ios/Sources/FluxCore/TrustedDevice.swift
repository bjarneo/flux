import Foundation

/// A paired device. Flux pins its certificate: a replacement certificate
/// is a re-pair, never a silent update. Mirrors Android
/// `core/TrustStore.kt TrustedDevice` (whose `certificate` is base64 DER).
public struct TrustedDevice: Sendable, Equatable, Codable {
    public var id: String
    public var name: String
    public var type: String
    /// Leaf certificate in DER. Compared byte-for-byte against the peer's
    /// presented certificate after every TLS handshake.
    public var certificateDER: Data
    public var lastIP: String
    public var isFlux: Bool

    public init(id: String, name: String, type: String, certificateDER: Data, lastIP: String = "", isFlux: Bool = false) {
        self.id = id
        self.name = name
        self.type = type
        self.certificateDER = certificateDER
        self.lastIP = lastIP
        self.isFlux = isFlux
    }
}

/// Keychain service for the trust list. Each device is one generic-password
/// item keyed by device ID, so uninstall wipes pairings only when the
/// Keychain is cleared (reinstall = re-pair in that case).
public enum TrustService {
    public static let service = "org.omarchy.flux.trust"
    /// Account holding the JSON-encoded sorted ID list (Keychain has no
    /// prefix scan through the `KeychainClient` façade).
    public static let indexAccount = "__index"

    static func encode(_ device: TrustedDevice) throws -> Data {
        try JSONEncoder().encode(device)
    }

    static func decode(_ data: Data) throws -> TrustedDevice {
        try JSONDecoder().decode(TrustedDevice.self, from: data)
    }

    static func encodeIndex(_ ids: [String]) throws -> Data {
        try JSONEncoder().encode(ids.sorted())
    }

    static func decodeIndex(_ data: Data) -> [String] {
        (try? JSONDecoder().decode([String].self, from: data)) ?? []
    }
}
