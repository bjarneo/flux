import Foundation

/// A paired device. Flux pins its certificate.
public struct TrustedDevice: Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var type: String
    /// The certificate in base64 DER.
    public var certificate: String
    public var lastIp: String = ""
    public var isFlux: Bool = false

    private enum CodingKeys: String, CodingKey {
        case id, name, type, certificate, lastIp, isFlux
    }

    public var certificateDER: [UInt8]? { Data(base64Encoded: certificate).map(Array.init) }
}

extension TrustedDevice {
    /// Reads an entry. The fields with a default can be missing, for
    /// example in a file from an older version.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = try c.decode(String.self, forKey: .name)
        type = try c.decode(String.self, forKey: .type)
        certificate = try c.decode(String.self, forKey: .certificate)
        lastIp = try c.decodeIfPresent(String.self, forKey: .lastIp) ?? ""
        isFlux = try c.decodeIfPresent(Bool.self, forKey: .isFlux) ?? false
    }
}

/// The list of paired devices, stored as JSON in the data directory.
public final class TrustStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var devices: [String: TrustedDevice] = [:]

    /// True when the file exists but does not read. A save would replace
    /// the pairings in it, so this store does not save.
    private var unreadable = false

    /// Reads the file. An entry that does not decode, or whose certificate
    /// does not decode, is not paired. When the file loses an entry this
    /// way, a copy stays in trusted.json.bad, because the next save writes
    /// only the good entries.
    public init(url: URL) {
        self.url = url
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            if FileManager.default.fileExists(atPath: url.path) {
                unreadable = true
                FluxLog.core.error("cannot read the paired devices in \(url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return
        }
        let (list, dropped) = Self.decode(data)
        for d in list { devices[d.id] = d }
        guard dropped > 0 else { return }
        let bad = url.appendingPathExtension("bad")
        try? FileManager.default.removeItem(at: bad)
        do {
            try FileManager.default.copyItem(at: url, to: bad)
            FluxLog.core.error("\(dropped) paired devices in \(url.path, privacy: .public) do not read and are not paired. A copy of the file is in \(bad.lastPathComponent, privacy: .public)")
        } catch {
            FluxLog.core.error("\(dropped) paired devices in \(url.path, privacy: .public) do not read, and the copy failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Decodes the entries one at a time. It returns the good entries and
    /// the number of entries that it dropped, or 1 when the file is not a
    /// JSON list.
    static func decode(_ data: Data) -> (devices: [TrustedDevice], dropped: Int) {
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else { return ([], 1) }
        let good = entries.compactMap(\.device).filter { $0.certificateDER.map { !$0.isEmpty } ?? false }
        return (good, entries.count - good.count)
    }

    /// 1 entry of the file, or nil when it does not decode.
    private struct Entry: Decodable {
        let device: TrustedDevice?

        init(from decoder: Decoder) throws {
            device = try? TrustedDevice(from: decoder)
        }
    }

    public func get(_ id: String) -> TrustedDevice? { lock.withLock { devices[id] } }
    public func all() -> [TrustedDevice] { lock.withLock { Array(devices.values) } }

    /// Adds or replaces a device. It returns false when the file could not
    /// be written. The device stays trusted until Flux quits.
    @discardableResult
    public func put(_ d: TrustedDevice) -> Bool {
        lock.withLock {
            devices[d.id] = d
            return save()
        }
    }

    public func update(_ id: String, _ fn: (inout TrustedDevice) -> Void) {
        lock.withLock {
            guard var d = devices[id] else { return }
            fn(&d)
            if d != devices[id] {
                devices[id] = d
                save()
            }
        }
    }

    public func remove(_ id: String) {
        lock.withLock {
            devices.removeValue(forKey: id)
            save()
        }
    }

    @discardableResult
    private func save() -> Bool {
        guard !unreadable else {
            FluxLog.core.error("did not save the paired devices: \(self.url.path, privacy: .public) did not read at the start")
            return false
        }
        let list = devices.values.sorted { $0.id < $1.id }
        do {
            let data = try JSONEncoder().encode(list)
            try data.write(to: url, options: [.atomic])
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            return true
        } catch {
            FluxLog.core.error("cannot save the paired devices in \(self.url.path, privacy: .public): \(String(describing: error), privacy: .public)")
            return false
        }
    }
}
