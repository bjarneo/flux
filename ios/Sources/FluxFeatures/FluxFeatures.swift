import Foundation
import FluxProto

/// Feature stubs with iOS limitation notes (full ports land in M2–M5).
/// Each router only sends packet types in `outgoingCapabilities` and gates
/// receives on `incomingCapabilities`, so `fluxd` capability intersection
/// keeps desktop UI honest.
public enum FluxFeatures {
    /// Battery: `UIDevice.batteryLevel` + `batteryState`, change-only.
    /// Threshold flag (≤15% and not charging) mirrors Go + Android.
    public static func batteryPacket(level: Int, charging: Bool) -> Packet {
        BatteryState(level: level, charging: charging).packet()
    }

    /// DND/Focus: iOS→desktop boolean only (`INFocusStatusCenter`).
    /// Desktop→iOS cannot be set programmatically — display a banner only.
    public static func dndPacket(on: Bool) -> Packet {
        .of(PacketType.fluxDnd, ("on", on))
    }

    /// SMS is an explicit non-goal for v1: no third-party SMS API on iOS.
    /// The Messages page shows "Not supported on iOS".
    public static let smsSupported = false

    /// Notifications: no global mirror on iOS. Only Flux-internal,
    /// CallKit missed-call, and desktop→iOS request rendering are supported.
    public static let notificationMirrorSupported = false
}
