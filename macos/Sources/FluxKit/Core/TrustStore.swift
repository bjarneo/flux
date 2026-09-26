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

    public var certificateDER: [UInt8]? { Data(base64Encoded: certificate).map(Array.init) }
}

/// The list of paired devices, stored as JSON in the data directory.
public final class TrustStore: @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()
    private var devices: [String: TrustedDevice] = [:]

    public init(url: URL) {
        self.url = url
        if let data = try? Data(contentsOf: url), let list = try? JSONDecoder().decode([TrustedDevice].self, from: data) {
            for d in list { devices[d.id] = d }
        }
    }

    public func get(_ id: String) -> TrustedDevice? { lock.withLock { devices[id] } }
    public func all() -> [TrustedDevice] { lock.withLock { Array(devices.values) } }

    public func put(_ d: TrustedDevice) {
        lock.withLock {
            devices[d.id] = d
            save()
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

    private func save() {
        let list = devices.values.sorted { $0.id < $1.id }
        guard let data = try? JSONEncoder().encode(list) else { return }
        try? data.write(to: url, options: [.atomic])
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
