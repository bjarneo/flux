import Foundation
import FluxProto

/// Local device identity: a stable device ID persisted in the Keychain.
///
/// - The ID is 32 lowercase hex chars (UUID without dashes), matching Go
///   `newUUID` (stripped) and Android's `UUID…replace("-","")`. It satisfies
///   `ValidDeviceID` (`^[a-zA-Z0-9_-]{32,38}$`).
/// - Keychain persistence means the ID — and therefore pairings — survives
///   app reinstalls **only while the Keychain entry is retained**. If the
///   Keychain is cleared (device wipe, "Erase All Content", or a different
///   device), the next launch generates a new ID and every desktop sees an
///   unknown device: **reinstall = re-pair**. The desktop side then shows
///   the classic "lost trust, confirm the key again" flow.
public enum DeviceID {
    public static let service = "org.omarchy.flux.identity"
    public static let account = "device-id"

    /// Generates a new random device ID.
    public static func make() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Loads the persisted ID or creates, persists, and returns a new one.
    /// Returns nil only when a stored value exists but is invalid (caller
    /// should wipe and retry, i.e. treat as a fresh install).
    public static func loadOrCreate(keychain: KeychainClient = .live()) -> String? {
        if let stored = keychain.load(service, account),
           let id = String(data: stored, encoding: .utf8),
           validDeviceId(id)
        {
            return id
        }
        if keychain.load(service, account) != nil {
            return nil
        }
        let id = make()
        keychain.save(service, account, Data(id.utf8))
        return id
    }
}
