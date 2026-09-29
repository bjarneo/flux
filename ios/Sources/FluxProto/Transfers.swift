import Foundation

/// M3 file-transfer + browse packets: `flux.tunnel` announcements,
/// `kdeconnect.sftp` offers, and `kdeconnect.share.request` payload
/// announcements for the sending side.
///
/// Sources of truth: `internal/lan/tunnel.go` (`TunnelReady`, `OpenTunnel`,
/// `pushPayload`), `internal/lan/payload.go` (`SendWithPayload`,
/// `FetchPayload`), `internal/core/sftp.go` (`handleBrowseRequest`),
/// Android `protocol/Tunnel.kt` (`TunnelPackets`, `SftpOffer`),
/// `core/Browse.kt` (`onCredentials`), `core/Share.kt`
/// (`receive`/`sendFiles`/`sendCapture`).
///
/// Port-vs-tunnel selection rule (plan §12 Q3, closed here):
/// - The SENDER chooses. Desktop `SendWithPayload` uses a tunnel when the
///   receiver advertises `flux.tunnel` in its outgoing capabilities
///   (`Link.CanTunnel`); otherwise it listens on a classic payload port
///   (1739–1764) and announces `port`.
/// - The RECEIVER follows the packet: a `tunnel` token means "listen and
///   answer `flux.tunnel {id, port}`"; a `port` means "connect and fetch".
/// - Phone→desktop is always classic: the phone opens the payload server
///   and announces `port` (Android `Share.sendFiles` parity — the desktop
///   never opens tunnel listeners, it only dials them via `DialPeer`).
/// - Consequence, shared with Go + Android: `hasPayload` requires
///   `payloadSize != 0`, so 0-byte files never transfer on any
///   implementation. A 0 B announcement is dropped without a fetch
///   (Android `Share.receive` returns early, Go `handleShare` falls
///   through); the E2E harness verifies that clean drop.

// MARK: - flux.tunnel

/// `flux.tunnel` packets. The phone opens a TLS listener and answers with
/// `{id, port}`, or `{id, error}` when it cannot (Android
/// `protocol/Tunnel.kt TunnelPackets`).
public enum TunnelPackets {
    /// Answers a tunnel token with the listener port (receiver→sender).
    public static func ready(token: String, port: Int) -> Packet {
        Packet.of(PacketType.fluxTunnel, ("id", token), ("port", port))
    }

    /// Answers a tunnel token with a failure (e.g. no free port, cannot
    /// save the file — Android `TunnelPackets.failed`).
    public static func failed(token: String, error: String) -> Packet {
        Packet.of(PacketType.fluxTunnel, ("id", token), ("error", error))
    }

    /// One parsed `flux.tunnel` packet. Returns nil for other types or a
    /// packet with no token.
    public static func parse(_ p: Packet) -> (token: String, port: Int, error: String?)? {
        guard p.type == PacketType.fluxTunnel else { return nil }
        guard let token = p.string("id"), !token.isEmpty else { return nil }
        return (token, p.int("port") ?? 0, p.string("error"))
    }
}

// MARK: - kdeconnect.sftp.request / kdeconnect.sftp

/// Browse-PC signalling. The phone asks with `sftp.request
/// {"startBrowsing": true}`; the desktop answers with `sftp` carrying
/// either `ip`+`port` (classic) or `tunnel` (phone listens, desktop dials —
/// `handleBrowseRequest`), or `errorMessage` (notably when `share_home`
/// is off). Serving iPhone files over SFTP is deferred (plan §4.7), so
/// the phone never sends `sftp` itself.
public enum SftpPackets {
    /// Asks the desktop for an SFTP session (Android `Browse.start`).
    public static func requestPacket() -> Packet {
        Packet.of(PacketType.sftpRequest, ("startBrowsing", true))
    }
}

/// The body of a `kdeconnect.sftp` offer. Port of Android
/// `protocol/Tunnel.kt SftpOffer`.
public struct SftpOffer: Sendable, Equatable {
    public var ip: String?
    public var port: Int
    public var tunnel: String?
    public var user: String
    public var password: String
    public var path: String
    /// `(displayName, path)` pairs from `pathNames`+`multiPaths`.
    public var roots: [(String, String)]

    public init(
        ip: String?, port: Int, tunnel: String?, user: String,
        password: String, path: String, roots: [(String, String)]
    ) {
        self.ip = ip
        self.port = port
        self.tunnel = tunnel
        self.user = user
        self.password = password
        self.path = path
        self.roots = roots
    }

    public static func == (lhs: SftpOffer, rhs: SftpOffer) -> Bool {
        lhs.ip == rhs.ip && lhs.port == rhs.port && lhs.tunnel == rhs.tunnel
            && lhs.user == rhs.user && lhs.password == rhs.password
            && lhs.path == rhs.path && lhs.roots.elementsEqual(rhs.roots, by: ==)
    }

    /// True when the desktop is behind a firewall: it connects to a phone
    /// listener instead of accepting connections (Android `viaTunnel`).
    public var viaTunnel: Bool { tunnel != nil && (ip == nil || port <= 0) }

    /// Parses a `kdeconnect.sftp` packet. Returns nil for error answers
    /// (read `errorMessage` instead) or a packet with no way to connect.
    public static func parse(_ p: Packet) -> SftpOffer? {
        guard p.type == PacketType.sftp else { return nil }
        if p.has("errorMessage") { return nil }
        guard let user = p.string("user"), !user.isEmpty,
              let password = p.string("password"), !password.isEmpty
        else { return nil }
        let ip = p.string("ip").flatMap { $0.isEmpty ? nil : $0 }
        let port = p.int("port") ?? 0
        let tunnel = p.string("tunnel").flatMap { $0.isEmpty ? nil : $0 }
        if tunnel == nil, port <= 0 { return nil }
        let path = p.string("path") ?? "/"
        let paths = p.strings("multiPaths")
        let names = p.strings("pathNames")
        let roots: [(String, String)] = (paths.count == names.count && !paths.isEmpty)
            ? zip(names, paths).map { ($0, $1) }
            : [("Home", path)]
        return SftpOffer(ip: ip, port: port, tunnel: tunnel, user: user, password: password, path: path, roots: roots)
    }

    /// The desktop's refusal reason (`share_home` off, no tunnel support…).
    public static func errorMessage(_ p: Packet) -> String? {
        guard p.type == PacketType.sftp else { return nil }
        return p.string("errorMessage")
    }
}

// MARK: - kdeconnect.share.request (sending side)

extension ShareMessage {
    /// Builds one file announcement for a classic payload server
    /// (Android `Share.sendFiles` / Go `sendFile` without a tunnel).
    public static func filePacket(
        filename: String, open: Bool = false, numberOfFiles: Int = 1,
        totalPayloadSize: Int64, payloadSize: Int64, payloadPort: Int,
        extra: [(String, Any?)] = []
    ) -> Packet {
        var body: [String: JSONValue] = [
            "filename": .string(filename),
            "open": .bool(open),
            "numberOfFiles": .integer(Int64(numberOfFiles)),
            "totalPayloadSize": .integer(totalPayloadSize),
        ]
        for (k, v) in extra { body[k] = JSONValue.make(v) }
        var p = Packet(type: PacketType.share, body: body)
        p.payloadSize = payloadSize
        p.payloadPort = payloadPort
        return p
    }
}
