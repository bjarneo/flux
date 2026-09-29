import Foundation
#if canImport(Security)
import Security
#endif

/// Minimal Keychain façade. Production uses `SecItem*` with
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`; tests and previews
/// use `.inMemory()`. Trust items are device-specific pins and are never
/// synchronized to iCloud (`kSecAttrSynchronizable = false`).
public struct KeychainClient: Sendable {
    public var load: @Sendable (String, String) -> Data?
    public var save: @Sendable (String, String, Data) -> Void
    public var delete: @Sendable (String, String) -> Void

    public init(
        load: @escaping @Sendable (String, String) -> Data?,
        save: @escaping @Sendable (String, String, Data) -> Void,
        delete: @escaping @Sendable (String, String) -> Void
    ) {
        self.load = load
        self.save = save
        self.delete = delete
    }

    /// Ephemeral dictionary backend. Same semantics as live (upsert on save,
    /// missing delete is a no-op) without touching the device Keychain.
    public static func inMemory() -> KeychainClient {
        final class Box: @unchecked Sendable {
            let lock = NSLock()
            var store: [String: Data] = [:]
        }
        let box = Box()
        return KeychainClient(
            load: { service, account in
                box.lock.withLock { box.store["\(service)\0\(account)"] }
            },
            save: { service, account, data in
                box.lock.withLock { box.store["\(service)\0\(account)"] = data }
            },
            delete: { service, account in
                box.lock.withLock { _ = box.store.removeValue(forKey: "\(service)\0\(account)") }
            }
        )
    }

    /// Live Keychain backend. Falls back to a no-op store where the
    /// Security framework is unavailable (Linux CI).
    public static func live() -> KeychainClient {
#if canImport(Security)
        KeychainClient(
            load: { service, account in KeychainLive.load(service: service, account: account) },
            save: { service, account, data in KeychainLive.save(service: service, account: account, data: data) },
            delete: { service, account in KeychainLive.delete(service: service, account: account) }
        )
#else
        inMemory()
#endif
    }
}

#if canImport(Security)
/// Thin `SecItem*` wrapper. accessibility is fixed: the daemon-equivalent
/// trust must be readable after first unlock without biometric auth.
/// (Biometric-gated keys are M6 approve keys, not identity/trust items.)
enum KeychainLive {
    static func load(service: String, account: String) -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess else { return nil }
        return item as? Data
    }

    static func save(service: String, account: String, data: Data) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let attributes: [String: Any] = [
            kSecValueData as String: data,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly,
        ]
        if SecItemUpdate(query as CFDictionary, attributes as CFDictionary) == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            add[kSecAttrSynchronizable as String] = false
            SecItemAdd(add as CFDictionary, nil)
        }
    }

    static func delete(service: String, account: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        SecItemDelete(query as CFDictionary)
    }
}
#endif
