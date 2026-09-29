import FluxKit
import Foundation

/// Sample computers for App Review and screenshots. With the launch argument
/// `-FLUX_DEMO 1`, the app shows them in place of the real computers and
/// starts no discovery, listener, or link, see `AppModel`. The core does not
/// know the sample computers, so the actions on their screens reach no
/// computer.
enum DemoMode {
    /// The defaults key that the launch argument sets.
    static let key = "FLUX_DEMO"

    /// True when the app started with `-FLUX_DEMO 1`.
    static var isOn: Bool { UserDefaults.standard.bool(forKey: key) }

    /// The state of the core with the sample computers in place of the real
    /// ones. Flux shows as on, not searching, and with no link port.
    static func state(_ core: CoreState) -> CoreState {
        var state = core
        state.devices = computers
        state.enabled = true
        state.searching = false
        state.tcpPort = 0
        return state
    }

    /// A connected laptop with the features of fluxd, and a desktop that is
    /// not reachable.
    static let computers: [DeviceSnapshot] = [
        computer(id: "demo_laptop_00000000000000000001", name: "omarchy", type: "laptop", ip: "192.168.1.20", online: true),
        computer(id: "demo_desktop_0000000000000000002", name: "workstation", type: "desktop", ip: "192.168.1.31", online: false),
    ]

    /// The packet types that fluxd accepts, from `Incoming` in
    /// internal/proto/identity.go, without the ones that only Android uses.
    static let incoming = [
        PacketType.ping, PacketType.battery, PacketType.clipboard, PacketType.clipboardConnect,
        PacketType.share, PacketType.shareUpdate, PacketType.notification, PacketType.runCommandRequest,
        PacketType.mprisRequest, PacketType.sftpRequest,
        PacketType.fluxTunnel, PacketType.fluxWebcam, PacketType.fluxDnd, PacketType.fluxMic, PacketType.fluxScreen,
        PacketType.fluxApprove, PacketType.fluxHerdr, PacketType.fluxClipboardImage, PacketType.mousepadRequest,
        PacketType.fluxDesktop, PacketType.fluxShortcuts,
    ]

    /// The packet types that fluxd sends, from `Outgoing` in
    /// internal/proto/identity.go, without the ones that only Android uses.
    static let outgoing = [
        PacketType.ping, PacketType.battery, PacketType.clipboard, PacketType.clipboardConnect, PacketType.share,
        PacketType.notification, PacketType.notificationRequest, PacketType.notificationReply, PacketType.notificationAction,
        PacketType.findMyPhone, PacketType.runCommand, PacketType.mpris,
        PacketType.sftp, PacketType.fluxWebcam, PacketType.fluxDnd,
        PacketType.fluxMic, PacketType.fluxScreen, PacketType.fluxApprove, PacketType.fluxHerdr,
        PacketType.fluxClipboardImage, PacketType.fluxInput, PacketType.fluxDesktop, PacketType.fluxShortcuts,
    ]

    private static func computer(id: String, name: String, type: String, ip: String, online: Bool) -> DeviceSnapshot {
        DeviceSnapshot(id: id, name: name, type: type, ip: ip, isFlux: true, paired: true, online: online,
                       pairState: .paired, pairKey: "", incoming: incoming, outgoing: outgoing)
    }
}
