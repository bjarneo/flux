import Foundation
import FluxProto

/// Paired-device record. `fluxd` owns the canonical state; the phone keeps a
/// Keychain-backed mirror (see `TrustStore.swift`).
public struct FluxDevice: Sendable, Equatable, Identifiable {
    public var id: String { deviceId }
    public var deviceId: String
    public var deviceName: String
    public var deviceType: String
    public var paired: Bool
    public var online: Bool

    public init(deviceId: String, deviceName: String, deviceType: String = "laptop", paired: Bool = false, online: Bool = false) {
        self.deviceId = deviceId
        self.deviceName = deviceName
        self.deviceType = deviceType
        self.paired = paired
        self.online = online
    }
}

/// App settings with iOS-safe defaults.
///
/// `autoClipboard` defaults to `false` on iOS: `UIPasteboard` is
/// foreground-only, so there is no background clipboard daemon.
public struct FluxSettings: Sendable, Equatable {
    public var autoClipboard: Bool = false
    public var shareFocusStatus: Bool = true
    public var autoUploadScreenshots: Bool = false

    public init() {}
}
