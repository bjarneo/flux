import Foundation

/// flux.ping in both directions.
public final class PingPlugin: FluxPlugin, @unchecked Sendable {
    private weak var core: FluxCore?

    public init() {}

    public let incoming = [PacketType.ping]
    public let outgoing = [PacketType.ping]

    public func attach(core: FluxCore) { self.core = core }

    public func handle(_ packet: Packet, from device: Device) {
        let message = packet.string("message") ?? "Ping"
        core?.toast("\(message) from \(device.name)")
    }

    /// Sends a ping to a paired, connected device.
    public func ping(_ deviceId: String) {
        guard let core else { return }
        if core.send(Packet(PacketType.ping), to: deviceId) {
            core.toast("Ping sent")
        } else {
            core.toast("Not connected. Try again in a moment")
        }
    }
}
