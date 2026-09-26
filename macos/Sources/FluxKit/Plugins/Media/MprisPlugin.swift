import Foundation
import Observation

/// The players of each computer, for the UI.
@MainActor
@Observable
public final class MediaModel {
    public private(set) var devices: [String: RemoteMedia] = [:]

    public init() {}

    public func media(_ deviceId: String) -> RemoteMedia { devices[deviceId] ?? RemoteMedia() }

    fileprivate func update<T>(_ deviceId: String, _ change: (inout RemoteMedia) -> T) -> T {
        var m = media(deviceId)
        let result = change(&m)
        devices[deviceId] = m
        return result
    }
}

/// kdeconnect.mpris.request out, kdeconnect.mpris in: this Mac controls the
/// media players on the computer.
public final class MprisPlugin: FluxPlugin, @unchecked Sendable {
    private weak var core: FluxCore?
    public let model: MediaModel

    @MainActor
    public init() { model = MediaModel() }

    public let incoming = [PacketType.mpris]
    public let outgoing = [PacketType.mprisRequest]

    public func attach(core: FluxCore) { self.core = core }

    /// The menu bar shows the current player, so the list loads on connect.
    public func onConnected(_ device: Device) {
        if device.accepts(PacketType.mprisRequest) {
            device.send(Packet(PacketType.mprisRequest, ["requestPlayerList": true]))
        }
    }

    public func handle(_ packet: Packet, from device: Device) {
        let id = device.id
        let now = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.async { [self] in
            MainActor.assumeIsolated {
                if let name = model.update(id, { $0.apply(packet, now: now) }) { requestNowPlaying(id, name) }
            }
        }
    }

    /// Asks for the player list and the state of the current player.
    @MainActor
    public func requestPlayers(_ deviceId: String) {
        core?.send(Packet(PacketType.mprisRequest, ["requestPlayerList": true]), to: deviceId)
        if let name = model.media(deviceId).current { requestNowPlaying(deviceId, name) }
    }

    /// Makes the player the one that this Mac controls.
    @MainActor
    public func select(_ deviceId: String, player name: String) {
        model.update(deviceId) { $0.current = name }
        requestNowPlaying(deviceId, name)
    }

    /// Sends PlayPause, Play, Pause, Next, Previous, or Stop to the current player.
    @MainActor
    public func action(_ deviceId: String, _ action: String) {
        guard let name = model.media(deviceId).current else { return }
        core?.send(Packet(PacketType.mprisRequest, ["player": name, "action": action]), to: deviceId)
        if action == "PlayPause" {
            let now = ProcessInfo.processInfo.systemUptime
            model.update(deviceId) { $0.togglePlaying(now: now) }
        }
    }

    /// Moves the current player to the position in milliseconds.
    @MainActor
    public func seek(_ deviceId: String, to position: Int64) {
        guard let name = model.media(deviceId).current else { return }
        core?.send(Packet(PacketType.mprisRequest, ["player": name, "SetPosition": position]), to: deviceId)
        let now = ProcessInfo.processInfo.systemUptime
        model.update(deviceId) { $0.seek(to: position, now: now) }
    }

    /// Sets the volume of the current player, from 0 to 100.
    @MainActor
    public func setVolume(_ deviceId: String, _ volume: Int) {
        guard let name = model.media(deviceId).current else { return }
        let volume = min(max(volume, 0), 100)
        core?.send(Packet(PacketType.mprisRequest, ["player": name, "setVolume": volume]), to: deviceId)
        model.update(deviceId) { $0.setVolume(volume) }
    }

    @MainActor
    private func requestNowPlaying(_ deviceId: String, _ name: String) {
        core?.send(Packet(PacketType.mprisRequest, ["player": name, "requestNowPlaying": true, "requestVolume": true]), to: deviceId)
    }
}
