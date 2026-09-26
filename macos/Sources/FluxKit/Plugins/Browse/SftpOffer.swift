import Foundation

/// A top folder that the computer shares, like Home or Downloads.
public struct BrowseRoot: Sendable, Equatable, Hashable {
    public var name: String
    public var path: String

    public init(name: String, path: String) {
        self.name = name
        self.path = path
    }
}

/// The body of kdeconnect.sftp. A computer that accepts connections sends
/// `ip` and `port`. A computer behind a firewall sends `tunnel` instead.
public struct SftpOffer: Sendable, Equatable {
    public var ip: String?
    public var port: Int
    public var tunnel: String?
    public var user: String
    public var password: String
    public var path: String
    public var roots: [BrowseRoot]

    /// True when the SSH session runs inside a Flux tunnel.
    public var viaTunnel: Bool { tunnel != nil && (ip == nil || port <= 0) }

    /// Parses kdeconnect.sftp. It returns nil for an error answer or a packet
    /// with no way to connect.
    public static func parse(_ p: Packet) -> SftpOffer? {
        guard p.type == PacketType.sftp, !p.has("errorMessage"),
              let user = p.string("user"), let password = p.string("password") else { return nil }
        let ip = p.string("ip").flatMap { $0.isEmpty ? nil : $0 }
        let port = p.int("port") ?? 0
        let tunnel = p.string("tunnel").flatMap { $0.isEmpty ? nil : $0 }
        if tunnel == nil && port <= 0 { return nil }
        let path = p.string("path") ?? "/"
        let paths = p.strings("multiPaths")
        let names = p.strings("pathNames")
        let roots = !paths.isEmpty && paths.count == names.count
            ? zip(names, paths).map { BrowseRoot(name: $0, path: $1) }
            : [BrowseRoot(name: "Home", path: path)]
        return SftpOffer(ip: ip, port: port, tunnel: tunnel, user: user, password: password, path: path, roots: roots)
    }
}
