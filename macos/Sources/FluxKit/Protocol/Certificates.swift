import Crypto
import _CryptoExtras
import Foundation
import NIOSSL
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
    /// The directory stays out of backups, also when an older version made
    /// it, see `excludeFromBackup(directory:)`.
    ///
    /// Flux makes a new identity only when a file is missing. Files that
    /// exist but cannot be read, for example before the first unlock of an
    /// iPhone, throw `IdentityUnreadable`. Files that do not parse throw
    /// `FluxError`. So a read error does not replace the identity and lose
    /// every pairing. The key file gets mode 0600 from the start.
    public static func loadOrCreate(directory: URL) throws -> LocalCertificate {
        let keyURL = directory.appendingPathComponent(keyFile)
        let certURL = directory.appendingPathComponent(certFile)
        let fm = FileManager.default
        let keyExists = fm.fileExists(atPath: keyURL.path)
        let certExists = fm.fileExists(atPath: certURL.path)
        if keyExists && certExists {
            let key: Data
            let der: Data
            do {
                key = try Data(contentsOf: keyURL)
                der = try Data(contentsOf: certURL)
            } catch {
                throw IdentityUnreadable("Cannot read the identity of this device in \(directory.path): \(error.localizedDescription)")
            }
            let loaded: LocalCertificate
            do {
                guard let pem = String(data: key, encoding: .utf8) else { throw FluxError("the key is not text") }
                // The TLS setup reads the key in the same way.
                _ = try NIOSSLPrivateKey(bytes: Array(pem.utf8), format: .pem)
                loaded = try LocalCertificate(privateKeyPEM: pem, certificateDER: Array(der))
            } catch {
                throw FluxError("The identity of this device in \(directory.path) is damaged: \(error)")
            }
            keepOutOfBackups(directory)
            // An older version wrote the key and its folder with the default mode.
            try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: keyURL.path)
            return loaded
        }
        if keyExists || certExists {
            // A first start that stopped between the 2 writes. The half
            // identity cannot link, so Flux makes a new one.
            FluxLog.core.error("the identity of this device is incomplete, Flux makes a new one")
        }
        let created = try generate(deviceId: UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased())
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        keepOutOfBackups(directory)
        try writePrivate(Data(created.privateKeyPEM.utf8), to: keyURL)
        try Data(created.certificateDER).write(to: certURL, options: [.atomic])
        return created
    }

    /// Writes data to a new file with mode 0600, then moves it into place,
    /// so that the key is never readable by other users.
    private static func writePrivate(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
            throw FluxError("Cannot write \(url.path)")
        }
        guard rename(temp.path, url.path) == 0 else {
            let code = errno
            try? FileManager.default.removeItem(at: temp)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EIO)
        }
    }

    /// Keeps the directory of the key and the certificate out of iCloud and
    /// computer backups on iOS. A backup that restores them on another
    /// iPhone gives 2 devices the same device ID and key. The Mac keeps its
    /// backups as they were. A missing directory is left alone.
    static func excludeFromBackup(directory: URL) throws {
        #if os(iOS)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
        #endif
    }

    /// Flux still starts when the exclusion fails. The identity then stays in backups.
    private static func keepOutOfBackups(_ directory: URL) {
        do {
            try excludeFromBackup(directory: directory)
        } catch {
            FluxLog.core.error("the identity stays in backups: \(String(describing: error), privacy: .public)")
        }
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

/// The number of hex digits of the verification key.
public let verificationKeyLength = 16

/// Returns the 16-digit key that both devices show while they pair: the
/// first 8 bytes of a SHA-256 of the 2 public keys, larger first, then the
/// pairing timestamp in seconds as decimal text when it is above 0. The
/// key has uppercase hex digits and no spaces. The apps show it in 4 groups
/// of 4, for example "5EE6 825F 974E D59A".
public func verificationKey(ownKey: [UInt8], peerKey: [UInt8], timestamp: Int64) -> String {
    var a = ownKey
    var b = peerKey
    if compareBytes(a, b) < 0 { swap(&a, &b) }
    var hash = SHA256()
    hash.update(data: a)
    hash.update(data: b)
    if timestamp > 0 { hash.update(data: Data(String(timestamp).utf8)) }
    let hex = hash.finalize().map { String(format: "%02x", $0) }.joined()
    return String(hex.prefix(verificationKeyLength)).uppercased()
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

/// The files of the identity exist, but Flux cannot read them now. Before
/// the first unlock after a restart, iOS keeps the files of an app locked.
/// A later start can read them, so the app can start the core again.
public struct IdentityUnreadable: Error, CustomStringConvertible, LocalizedError, Sendable {
    public let description: String
    public init(_ message: String) { description = message }
    public var errorDescription: String? { description }
}
