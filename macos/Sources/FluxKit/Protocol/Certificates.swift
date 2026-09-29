import Crypto
import _CryptoExtras
import Foundation
import SwiftASN1
import X509

/// The key and the self-signed certificate of this device.
public struct LocalCertificate: Sendable {
    /// The RSA private key in PEM form.
    public let privateKeyPEM: String
    /// The certificate in DER form.
    public let certificateDER: [UInt8]
    /// The device ID is the common name of the certificate.
    public let deviceId: String

    static let keyFile = "privateKey.pem"
    static let certFile = "certificate.der"

    public init(privateKeyPEM: String, certificateDER: [UInt8]) throws {
        guard let cn = commonName(der: certificateDER) else { throw FluxError("certificate has no CN") }
        self.privateKeyPEM = privateKeyPEM
        self.certificateDER = certificateDER
        self.deviceId = cn
    }

    /// Loads the certificate from the directory. The first call generates a
    /// new RSA 2048 key and a certificate with CN set to a new device ID.
    public static func loadOrCreate(directory: URL) throws -> LocalCertificate {
        let keyURL = directory.appendingPathComponent(keyFile)
        let certURL = directory.appendingPathComponent(certFile)
        if let pem = try? String(contentsOf: keyURL, encoding: .utf8), let der = try? Data(contentsOf: certURL),
           let loaded = try? LocalCertificate(privateKeyPEM: pem, certificateDER: Array(der)) {
            return loaded
        }
        let created = try generate(deviceId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(created.privateKeyPEM.utf8).write(to: keyURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
        try Data(created.certificateDER).write(to: certURL, options: [.atomic])
        return created
    }

    /// Generates a self-signed certificate with the device ID as its common name.
    public static func generate(deviceId: String) throws -> LocalCertificate {
        let rsa = try _RSA.Signing.PrivateKey(keySize: .bits2048)
        let key = Certificate.PrivateKey(rsa)
        let name = try DistinguishedName {
            CommonName(deviceId)
            OrganizationalUnitName("Flux")
            OrganizationName("Omarchy")
        }
        let now = Date()
        let cert = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(bytes: [1]),
            publicKey: key.publicKey,
            notValidBefore: now.addingTimeInterval(-365 * 86400),
            notValidAfter: now.addingTimeInterval(10 * 365 * 86400),
            issuer: name,
            subject: name,
            signatureAlgorithm: .sha256WithRSAEncryption,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
            },
            issuerPrivateKey: key
        )
        var serializer = DER.Serializer()
        try serializer.serialize(cert)
        return try LocalCertificate(privateKeyPEM: rsa.pemRepresentation, certificateDER: serializer.serializedBytes)
    }
}

/// Returns the CN of the certificate subject.
public func commonName(der: [UInt8]) -> String? {
    guard let cert = try? Certificate(derEncoded: der) else { return nil }
    for rdn in cert.subject {
        for attribute in rdn where attribute.type == .RDNAttributeType.commonName {
            return String(describing: attribute.value)
        }
    }
    return nil
}

/// Returns the SubjectPublicKeyInfo DER bytes exactly as the certificate holds them.
public func subjectPublicKeyInfo(der: [UInt8]) throws -> [UInt8] {
    // Certificate ::= SEQUENCE { tbsCertificate, signatureAlgorithm, signature }
    // TBSCertificate ::= SEQUENCE { [0] version OPTIONAL, serialNumber,
    //   signature, issuer, validity, subject, subjectPublicKeyInfo, ... }
    let root = try DER.parse(der)
    guard case .constructed(let certChildren) = root.content,
          let tbs = certChildren.first(where: { _ in true }),
          case .constructed(let tbsChildren) = tbs.content else { throw FluxError("malformed certificate") }
    var fields = Array(tbsChildren)
    if let first = fields.first, first.identifier.tagClass == .contextSpecific, first.identifier.tagNumber == 0 {
        fields.removeFirst()
    }
    // serialNumber, signature, issuer, validity, subject, subjectPublicKeyInfo
    guard fields.count >= 6 else { throw FluxError("malformed certificate") }
    return Array(fields[5].encodedBytes)
}

/// Returns the 8-character key that both devices show while they pair. It
/// hashes the 2 public keys, larger first, then the pairing timestamp in
/// seconds as decimal text.
public func verificationKey(ownKey: [UInt8], peerKey: [UInt8], timestamp: Int64) -> String {
    var a = ownKey
    var b = peerKey
    if compareBytes(a, b) < 0 { swap(&a, &b) }
    var hash = SHA256()
    hash.update(data: a)
    hash.update(data: b)
    if timestamp > 0 { hash.update(data: Data(String(timestamp).utf8)) }
    let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(8)).uppercased()
}

public func verificationKey(ownCertificate: [UInt8], peerCertificate: [UInt8], timestamp: Int64) -> String {
    guard let own = try? subjectPublicKeyInfo(der: ownCertificate), let peer = try? subjectPublicKeyInfo(der: peerCertificate) else { return "" }
    return verificationKey(ownKey: own, peerKey: peer, timestamp: timestamp)
}

/// Compares bytes as unsigned values, the same way Go bytes.Compare does.
public func compareBytes(_ a: [UInt8], _ b: [UInt8]) -> Int {
    for i in 0..<min(a.count, b.count) where a[i] != b[i] {
        return Int(a[i]) - Int(b[i])
    }
    return a.count - b.count
}

/// A Flux error with a message for the user.
public struct FluxError: Error, CustomStringConvertible, LocalizedError, Sendable {
    public let description: String
    public init(_ message: String) { description = message }
    public var errorDescription: String? { description }
}
