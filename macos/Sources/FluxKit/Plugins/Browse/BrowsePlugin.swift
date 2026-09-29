import Foundation

/// Browse files on the computer, read-only. This Mac asks with
/// flux.sftp.request. The computer answers with flux.sftp: a
/// tunnel token, the user, and a one-time password. fluxd then
/// connects to a tunnel listener on this Mac, and the SSH session runs
/// inside the tunnel.
public final class BrowsePlugin: FluxPlugin, @unchecked Sendable {
    /// The notification category of finished downloads.
    public static let downloadCategory = "browse.download"
    /// The userInfo key with the path of the downloaded file.
    public static let pathKey = "path"

    private weak var core: FluxCore?
    /// The open browse windows by device ID.
    @MainActor private var browsers: [String: BrowseModel] = [:]

    public init() {}

    public let incoming = [PacketType.sftp]
    public let outgoing = [PacketType.sftpRequest, PacketType.fluxTunnel]

    public func attach(core: FluxCore) { self.core = core }

    /// The browser of a device. A new browser asks the computer for a session.
    @MainActor
    public func browser(for deviceId: String) -> BrowseModel? {
        if let b = browsers[deviceId] { return b }
        guard let core else { return nil }
        let b = BrowseModel(core: core, deviceId: deviceId)
        browsers[deviceId] = b
        b.start()
        return b
    }

    /// Ends the session of a device's browser, when its window closes.
    @MainActor
    public func close(_ deviceId: String) {
        browsers.removeValue(forKey: deviceId)?.close()
    }

    public func handle(_ packet: Packet, from device: Device) {
        guard let core else { return }
        let tls = core.tls, certificate = device.certificate, id = device.id
        Task { @MainActor in
            self.browsers[id]?.receive(packet, tls: tls, certificate: certificate)
        }
    }

    public func onConnected(_ device: Device) {
        let id = device.id
        Task { @MainActor in self.browsers[id]?.connected() }
    }

    public func onDisconnected(_ device: Device) {
        let id = device.id
        Task { @MainActor in self.browsers[id]?.disconnected() }
    }
}
