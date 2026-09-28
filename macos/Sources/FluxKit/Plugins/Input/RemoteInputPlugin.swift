import Foundation
import Observation

/// Whether each computer accepts remote input and shows its screen, for the UI.
@MainActor
@Observable
public final class RemoteInputModel {
    /// The last flux.input of each computer. A computer that has not told
    /// this Mac yet has no entry.
    public private(set) var enabled: [String: Bool] = [:]
    /// The `desktop` field of the last flux.input: true while the computer
    /// shows its screen to this Mac.
    public private(set) var desktop: [String: Bool] = [:]

    public init() {}

    /// True when remote input is on at the computer.
    public func isOn(_ deviceId: String) -> Bool { enabled[deviceId] == true }

    /// True when the remote desktop is on at the computer.
    public func isDesktopOn(_ deviceId: String) -> Bool { desktop[deviceId] == true }

    func set(_ deviceId: String, _ on: Bool, desktop shows: Bool? = nil) {
        enabled[deviceId] = on
        desktop[deviceId] = shows
    }
}

/// kdeconnect.mousepad.request out, flux.input in: the trackpad, the mouse,
/// and the keyboard of this Mac control the pointer and the keys of the
/// computer. The computer runs the input only while its remote_input
/// setting is on. It sends flux.input {"enabled": bool, "desktop": bool}
/// after the link starts and after a setting changes. `desktop` tells
/// whether remote_desktop is on, for `DesktopPlugin`.
public final class RemoteInputPlugin: FluxPlugin, @unchecked Sendable {
    private weak var core: FluxCore?
    public let model: RemoteInputModel

    public let incoming = [PacketType.fluxInput]
    public let outgoing = [PacketType.mousepadRequest]

    @MainActor
    public init() { model = RemoteInputModel() }

    public func attach(core: FluxCore) { self.core = core }

    /// True when the computer takes remote input. An older fluxd does not
    /// list kdeconnect.mousepad.request.
    public static func supported(_ device: DeviceSnapshot) -> Bool { device.accepts(PacketType.mousepadRequest) }

    public func handle(_ packet: Packet, from device: Device) {
        guard let on = packet.bool("enabled") else { return }
        let desktop = packet.bool("desktop")
        let shows = desktop.map { $0 ? "on" : "off" } ?? "not reported"
        FluxLog.plugin.info("remote input is \(on ? "on" : "off", privacy: .public), remote desktop is \(shows, privacy: .public) on \(device.name, privacy: .public)")
        let id = device.id
        let model = model
        DispatchQueue.main.async { MainActor.assumeIsolated { model.set(id, on, desktop: desktop) } }
    }

    /// Sends 1 input packet. It returns false when the computer is offline.
    @discardableResult
    public func send(_ packet: Packet, to deviceId: String) -> Bool { core?.send(packet, to: deviceId) ?? false }
}
