import Foundation

/// LAN constants. Source of truth: `internal/lan/tls.go` and
/// `internal/lan/link.go`. Do not hardcode KDE Connect defaults from memory.
public enum Lan {
    /// UDP discovery port.
    public static let udpPort = 1716
    public static let minTCPPort = 1716
    public static let maxTCPPort = 1764
    public static let minPayloadPort = 1739
    public static let maxPayloadPort = 1764
    /// Max identity line over TCP (64 KiB like Go `maxIdentitySize`).
    public static let maxIdentitySize = 64 << 10
    /// Race window in which a second link counts as simultaneous, not a reconnect.
    public static let raceWindow: TimeInterval = 5
    /// mDNS service type for KDE Connect discovery.
    public static let mdnsServiceType = "_kdeconnect._udp"
}
