import CryptoKit
import Foundation
import LocalAuthentication
import Security

/// An enrolled approval key, as the UI shows it.
public struct ApproveKeyInfo: Sendable, Equatable {
    public var host: String
    public var user: String
    /// The public key in DER.
    public var publicKey: Data
    public var enrolled: Date

    /// The key code that the terminal showed at enrollment.
    public var code: String { ApproveMessage.fingerprint(publicKey) }
}

/// The approval keys of this Mac, 1 for each paired computer.
///
/// Each key is an EC P-256 key in the Secure Enclave. Its access control
/// needs Touch ID for each signature, with no time window, and only the
/// fingerprints that exist when Flux makes the key (`.biometryCurrentSet`).
/// The key works only while this Mac is unlocked. A new fingerprint makes the
/// key invalid, and the user enrolls again.
///
/// The private key never leaves the Secure Enclave. Flux stores the blob that
/// the Secure Enclave wrapped with its own key, so only the Secure Enclave of
/// this Mac can use it, and only after Touch ID. A key without the keychain
/// needs no keychain entitlement, so it works in an ad-hoc signed app.
/// docs/approve.md is the design.
struct ApproveKeys: Sendable {
    let directory: URL

    /// What Flux stores for 1 key, in `<computer ID>.json` with mode 0600.
    private struct Record: Codable {
        /// The Secure Enclave blob of the private key.
        var key: Data
        var publicKey: Data
        /// The Touch ID fingerprint state when Flux made the key.
        var biometry: Data?
        var host: String
        var user: String
        /// Unix time in seconds.
        var enrolled: Int64
    }

    private func url(_ computerId: String) -> URL? {
        validDeviceId(computerId) ? directory.appendingPathComponent(computerId + ".json") : nil
    }

    private func record(_ computerId: String) -> Record? {
        guard let url = url(computerId), let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    func has(_ computerId: String) -> Bool { record(computerId) != nil }

    /// Every enrolled key, by computer ID.
    func all() -> [String: ApproveKeyInfo] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        var out: [String: ApproveKeyInfo] = [:]
        for file in files where file.pathExtension == "json" {
            let id = file.deletingPathExtension().lastPathComponent
            guard let r = record(id) else { continue }
            out[id] = ApproveKeyInfo(host: r.host, user: r.user, publicKey: r.publicKey, enrolled: Date(timeIntervalSince1970: TimeInterval(r.enrolled)))
        }
        return out
    }

    func delete(_ computerId: String) {
        guard let url = url(computerId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Stores a new key for the computer. It replaces the old key.
    func save(blob: Data, publicKey: Data, computerId: String, host: String, user: String) throws {
        guard let url = url(computerId) else { throw FluxError("The computer ID is not valid") }
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try excludeFromBackup()
        let r = Record(key: blob, publicKey: publicKey, biometry: Self.biometryState(), host: host, user: user,
                       enrolled: Int64(Date().timeIntervalSince1970))
        try JSONEncoder().encode(r).write(to: url, options: .atomic)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Keeps the folder out of iCloud and computer backups on iOS. Only the
    /// Secure Enclave of this iPhone can use a blob, so a blob that a backup
    /// restores on another iPhone fails. A missing folder is left alone. The
    /// Mac keeps its backups as they were.
    func excludeFromBackup() throws {
        #if os(iOS)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        var url = directory
        try url.setResourceValues(values)
        #endif
    }

    /// Makes a new key in the Secure Enclave. Each signature of the key asks
    /// for Touch ID through the context.
    static func create(context: LAContext) throws -> SecureEnclave.P256.Signing.PrivateKey {
        var error: Unmanaged<CFError>?
        guard let access = SecAccessControlCreateWithFlags(
            nil, kSecAttrAccessibleWhenUnlockedThisDeviceOnly, [.privateKeyUsage, .biometryCurrentSet], &error
        ) else {
            throw error.map { $0.takeRetainedValue() as Error } ?? FluxError("The access control is not valid")
        }
        return try SecureEnclave.P256.Signing.PrivateKey(accessControl: access, authenticationContext: context)
    }

    /// Loads the key of the computer. Each signature asks for Touch ID
    /// through the context.
    func signer(computerId: String, context: LAContext) throws -> SecureEnclave.P256.Signing.PrivateKey {
        guard let r = record(computerId) else { throw FluxError("No approval key for this computer") }
        return try SecureEnclave.P256.Signing.PrivateKey(dataRepresentation: r.key, authenticationContext: context)
    }

    /// Reports whether the Touch ID fingerprints changed since Flux made the
    /// key of the computer. The Secure Enclave then refuses the key.
    func biometryChanged(computerId: String) -> Bool {
        guard let stored = record(computerId)?.biometry, let now = Self.biometryState() else { return false }
        return stored != now
    }

    /// The state of the Touch ID fingerprints, or nil without Touch ID.
    static func biometryState() -> Data? {
        let c = LAContext()
        guard c.canEvaluatePolicy(.deviceOwnerAuthenticationWithBiometrics, error: nil) else { return nil }
        return c.evaluatedPolicyDomainState
    }
}
