import Foundation

/// Trust-store abstraction. Production backend is Keychain
/// (`kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`, never synced);
/// tests use `InMemoryTrustStore`. Mirrors Android `core/TrustStore.kt`.
public protocol TrustStore: Sendable {
    func trustedDevice(id: String) async -> TrustedDevice?
    func allDevices() async -> [TrustedDevice]
    func put(_ device: TrustedDevice) async
    func update(id: String, _ fn: @Sendable (TrustedDevice) -> TrustedDevice) async
    func isTrusted(deviceId: String) async -> Bool
    func setTrusted(deviceId: String, certificateDER: Data) async
    func remove(deviceId: String) async
    func certificateDER(for deviceId: String) async -> Data?
}

public extension TrustStore {
    func isTrusted(deviceId: String) async -> Bool {
        await trustedDevice(id: deviceId) != nil
    }

    func setTrusted(deviceId: String, certificateDER: Data) async {
        if let existing = await trustedDevice(id: deviceId) {
            var next = existing
            next.certificateDER = certificateDER
            await put(next)
        } else {
            await put(TrustedDevice(id: deviceId, name: deviceId, type: "laptop", certificateDER: certificateDER))
        }
    }

    func certificateDER(for deviceId: String) async -> Data? {
        await trustedDevice(id: deviceId)?.certificateDER
    }
}

/// In-memory trust store for previews, tests, and spikes.
public actor InMemoryTrustStore: TrustStore {
    private var store: [String: TrustedDevice] = [:]

    public init() {}

    public func trustedDevice(id: String) -> TrustedDevice? { store[id] }

    public func allDevices() -> [TrustedDevice] { Array(store.values) }

    public func put(_ device: TrustedDevice) {
        store[device.id] = device
    }

    public func update(id: String, _ fn: @Sendable (TrustedDevice) -> TrustedDevice) {
        guard let d = store[id] else { return }
        store[id] = fn(d)
    }

    public func remove(deviceId: String) {
        store.removeValue(forKey: deviceId)
    }
}

/// Keychain-backed trust store. One generic-password item per device under
/// `TrustService.service`, JSON-encoded like Android's shared preferences,
/// plus an `__index` item with the sorted ID list (Keychain has no prefix
/// scan through the `KeychainClient` façade).
public actor KeychainTrustStore: TrustStore {
    private let keychain: KeychainClient
    private let service: String

    public init(keychain: KeychainClient = .live(), service: String = TrustService.service) {
        self.keychain = keychain
        self.service = service
    }

    public func trustedDevice(id: String) -> TrustedDevice? {
        guard let data = keychain.load(service, id) else { return nil }
        return try? TrustService.decode(data)
    }

    public func allDevices() -> [TrustedDevice] {
        let ids = TrustService.decodeIndex(keychain.load(service, TrustService.indexAccount) ?? Data())
        var out: [TrustedDevice] = []
        for id in ids {
            if let d = trustedDevice(id: id) { out.append(d) }
        }
        return out.sorted { $0.id < $1.id }
    }

    public func put(_ device: TrustedDevice) {
        guard let data = try? TrustService.encode(device) else { return }
        keychain.save(service, device.id, data)
        var ids = Set(TrustService.decodeIndex(keychain.load(service, TrustService.indexAccount) ?? Data()))
        ids.insert(device.id)
        if let index = try? TrustService.encodeIndex(Array(ids)) {
            keychain.save(service, TrustService.indexAccount, index)
        }
    }

    public func update(id: String, _ fn: @Sendable (TrustedDevice) -> TrustedDevice) {
        guard let data = keychain.load(service, id),
              let decoded = try? TrustService.decode(data),
              let next = try? TrustService.encode(fn(decoded))
        else { return }
        keychain.save(service, id, next)
    }

    public func remove(deviceId: String) {
        keychain.delete(service, deviceId)
        var ids = Set(TrustService.decodeIndex(keychain.load(service, TrustService.indexAccount) ?? Data()))
        ids.remove(deviceId)
        if let index = try? TrustService.encodeIndex(Array(ids)) {
            keychain.save(service, TrustService.indexAccount, index)
        }
    }
}
